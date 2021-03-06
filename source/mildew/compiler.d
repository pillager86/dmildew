/**
This module implements the bytecode compiler

────────────────────────────────────────────────────────────────────────────────

Copyright (C) 2021 pillager86.rf.gd

This program is free software: you can redistribute it and/or modify it under 
the terms of the GNU General Public License as published by the Free Software 
Foundation, either version 3 of the License, or (at your option) any later 
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with 
this program.  If not, see <https://www.gnu.org/licenses/>.
*/
module mildew.compiler;

debug import std.stdio;
import std.typecons;
import std.variant;

import mildew.exceptions;
import mildew.lexer;
import mildew.parser;
import mildew.nodes;
import mildew.types;
import mildew.util.encode;
import mildew.util.stack;
import mildew.visitors;
import mildew.vm.consttable;
import mildew.vm.debuginfo;
import mildew.vm.program;
import mildew.vm.virtualmachine;

private enum BREAKLOOP_CODE = uint.max;
private enum BREAKSWITCH_CODE = uint.max - 1;
private enum CONTINUE_CODE = uint.max - 2;

/**
 * Implements a bytecode compiler that can be used by mildew.vm.virtualmachine. This class is not thread safe and each thread
 * must use its own Compiler instance. Only one program can be compiled at a time.
 */
class Compiler : INodeVisitor
{
public:

    /// thrown when a feature is missing
    class UnimplementedException : Exception
    {
        /// constructor
        this(string msg, string file=__FILE__, size_t line = __LINE__)
        {
            super(msg, file, line);
        }
    }

    /// compile code into chunk usable by vm
    Program compile(string source, string name = "<program>")
    {
        import core.memory: GC;
        import std.string: splitLines;

        auto oldChunk = _chunk; // @suppress(dscanner.suspicious.unmodified)
        _chunk = [];
        // auto oldConstTable = _constTable; // @suppress(dscanner.suspicious.unmodified)
        _constTable = _constTable is null ? new ConstTable() : _constTable;
        // todo fix with try-finally block
        _currentSource = source;
        _compDataStack.push(CompilationData.init);
        auto lexer = Lexer(source);
        auto parser = Parser(lexer.tokenize());
        _debugInfoStack.push(new DebugInfo(source));
        auto block = parser.parseProgram();
        block.accept(this);
        destroy(block);
        GC.free(cast(void*)block);
        block = null;

        // add a return statement
        (new ReturnStatementNode(0, null)).accept(this);

        _debugMap[_chunk.idup] = _debugInfoStack.pop;
        Program send = new Program(
            _constTable, 
            new ScriptFunction(name, ["module", "exports"], _chunk),
            _debugMap
        );
        _chunk = oldChunk;
        // _constTable = oldConstTable;
        _compDataStack.pop();
        _currentSource = null;

        return send;
    }

    /**
     * This is strictly for use by the Parser to evaluate case expressions and such.
     */
    package Program compile(StatementNode[] statements)
    {
        auto oldChunk = _chunk; // @suppress(dscanner.suspicious.unmodified)
        _chunk = [];
        auto oldConstTable = _constTable; // @suppress(dscanner.suspicious.unmodified)

        _constTable = new ConstTable();

        _compDataStack.push(CompilationData.init);
        _debugInfoStack.push(new DebugInfo(""));
        auto block = new BlockStatementNode(1, statements);
        block.accept(this);
        destroy(block);
        _debugMap[_chunk.idup] = _debugInfoStack.pop;
        auto send = new Program(
            _constTable,
            new ScriptFunction("<ctfe>", [], _chunk),
            _debugMap
        );
        _compDataStack.pop();

        _chunk = oldChunk;
        _constTable = oldConstTable;

        return send;
    }

// The visitNode methods are not intended for public use but are required to be public by D language constraints

    /// handle literal value node (easiest)
    Variant visitLiteralNode(LiteralNode lnode)
    {
        // want booleans to be booleans not 1
        if(lnode.value.type == ScriptAny.Type.BOOLEAN)
        {
            _chunk ~= OpCode.CONST ~ encodeConst(lnode.value.toValue!bool);
            return Variant(null);
        }

        if(lnode.value == ScriptAny(0))
            _chunk ~= OpCode.CONST_0;
        else if(lnode.value == ScriptAny(1))
            _chunk ~= OpCode.CONST_1;
        else
            _chunk ~= OpCode.CONST ~ encodeConst(lnode.value);

        if(lnode.literalToken.type == Token.Type.REGEX)
            _chunk ~= OpCode.REGEX;
        return Variant(null);
    }

    /// handle function literals. The VM should create new functions with the appropriate context
    ///  when a function is loaded from the const table
    Variant visitFunctionLiteralNode(FunctionLiteralNode flnode)
    {
        auto oldChunk = _chunk; // @suppress(dscanner.suspicious.unmodified)
        _compDataStack.push(CompilationData.init);
        _compDataStack.top.stackVariables.push(VarTable.init);
        _debugInfoStack.push(new DebugInfo(_currentSource, flnode.optionalName));
        ++_funcDepth;
        _chunk = [];

        // handle default args
        immutable startArgIndex = flnode.argList.length - flnode.defaultArguments.length;
        for(size_t i = startArgIndex; i < flnode.argList.length; ++i)
        {
            auto ifToEmit = new IfStatementNode(flnode.token.position.line,
                new BinaryOpNode(Token.createFakeToken(Token.Type.STRICT_EQUALS, "==="), 
                    new VarAccessNode(Token.createFakeToken(Token.Type.IDENTIFIER, flnode.argList[i])),
                    new LiteralNode(Token.createFakeToken(Token.Type.KEYWORD, "undefined"), ScriptAny.UNDEFINED)
                ), 
                new ExpressionStatementNode(flnode.token.position.line, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, "="),
                        new VarAccessNode(Token.createFakeToken(Token.Type.IDENTIFIER, flnode.argList[i])),
                        flnode.defaultArguments[i - startArgIndex]
                    )
                ), 
                null
            );
            ifToEmit.accept(this);
        }

        foreach(stmt ; flnode.statements)
            stmt.accept(this);
        // add a return undefined statement in case missing one
        _chunk ~= OpCode.STACK_1;
        _chunk ~= OpCode.RETURN;
        // create function
        ScriptAny func;
        if(!flnode.isClass)
            func = new ScriptFunction(
                flnode.optionalName == "" ? "<anonymous function>" : flnode.optionalName, 
                flnode.argList, _chunk, false, flnode.isGenerator, _constTable);
        else
            func = new ScriptFunction(
                flnode.optionalName == "" ? "<anonymous class>" : flnode.optionalName,
                flnode.argList, _chunk, true, false, _constTable);
        _debugMap[_chunk.idup] = _debugInfoStack.pop();
        _chunk = oldChunk;
        _compDataStack.top.stackVariables.pop;
        _compDataStack.pop();
        --_funcDepth;
        _chunk ~= OpCode.CONST ~ encodeConst(func);
        return Variant(null);
    }

    /// handle lambdas
    Variant visitLambdaNode(LambdaNode lnode)
    {
        FunctionLiteralNode flnode;
        if(lnode.returnExpression)
        {
            // lambda arrows should be on the same line as the expression unless the author is a psychopath
            flnode = new FunctionLiteralNode(lnode.arrowToken, lnode.argList, lnode.defaultArguments, [
                    new ReturnStatementNode(lnode.arrowToken.position.line, lnode.returnExpression)
                ], "<lambda>", false);
        }
        else
        {
            flnode = new FunctionLiteralNode(lnode.arrowToken, lnode.argList, lnode.defaultArguments, 
                    lnode.statements, "<lambda>", false);
        }
        flnode.accept(this);
        return Variant(null);
    }

    /// handles template strings
    Variant visitTemplateStringNode(TemplateStringNode tsnode)
    {
        foreach(node ; tsnode.nodes)
        {
            node.accept(this);
        }
        _chunk ~= OpCode.CONCAT ~ encode!uint(cast(uint)tsnode.nodes.length);
        return Variant(null);
    }

    /// handle array literals
    Variant visitArrayLiteralNode(ArrayLiteralNode alnode)
    {
        foreach(node ; alnode.valueNodes)
        {
            node.accept(this);
        }
        _chunk ~= OpCode.ARRAY ~ encode!uint(cast(uint)alnode.valueNodes.length);
        return Variant(null);
    }

    /// handle object literal nodes
    Variant visitObjectLiteralNode(ObjectLiteralNode olnode)
    {
        assert(olnode.keys.length == olnode.valueNodes.length);
        for(size_t i = 0; i < olnode.keys.length; ++i)
        {
            _chunk ~= OpCode.CONST ~ encodeConst(olnode.keys[i]);
            olnode.valueNodes[i].accept(this);            
        }
        _chunk ~= OpCode.OBJECT ~ encode(cast(uint)olnode.keys.length);
        return Variant(null);
    }

    /// Class literals. Parser is supposed to make sure string-function pairs match up
    Variant visitClassLiteralNode(ClassLiteralNode clnode)
    {
        // first make sure the data will fit in a 5 byte instruction
        if(clnode.classDefinition.methods.length > ubyte.max
        || clnode.classDefinition.getMethods.length > ubyte.max 
        || clnode.classDefinition.setMethods.length > ubyte.max
        || clnode.classDefinition.staticMethods.length > ubyte.max)
        {
            throw new ScriptCompileException("Class attributes exceed 255", clnode.classToken);
        }

        if(clnode.classDefinition.baseClass)
            _baseClassStack ~= clnode.classDefinition.baseClass;

        // method names then their functions
        immutable ubyte numMethods = cast(ubyte)clnode.classDefinition.methods.length;
        foreach(methodName ; clnode.classDefinition.methodNames)
            _chunk ~= OpCode.CONST ~ encodeConst(methodName);
        foreach(methodNode ; clnode.classDefinition.methods)
            methodNode.accept(this);
        
        // getter names then their functions
        immutable ubyte numGetters = cast(ubyte)clnode.classDefinition.getMethods.length;
        foreach(getName ; clnode.classDefinition.getMethodNames)
            _chunk ~= OpCode.CONST ~ encodeConst(getName);
        foreach(getNode ; clnode.classDefinition.getMethods)
            getNode.accept(this);
        
        // setter names then their functions
        immutable ubyte numSetters = cast(ubyte)clnode.classDefinition.setMethods.length;
        foreach(setName ; clnode.classDefinition.setMethodNames)
            _chunk ~= OpCode.CONST ~ encodeConst(setName);
        foreach(setNode ; clnode.classDefinition.setMethods)
            setNode.accept(this);
        
        // static names then their functions
        immutable ubyte numStatics = cast(ubyte)clnode.classDefinition.staticMethods.length;
        foreach(staticName ; clnode.classDefinition.staticMethodNames)
            _chunk ~= OpCode.CONST ~ encodeConst(staticName);
        foreach(staticNode ; clnode.classDefinition.staticMethods)
            staticNode.accept(this);
        
        // constructor (parse guarantees it exists)
        clnode.classDefinition.constructor.accept(this);
        // then finally base class
        if(clnode.classDefinition.baseClass)
            clnode.classDefinition.baseClass.accept(this);
        else
            _chunk ~= OpCode.STACK_1;

        _chunk ~= OpCode.CLASS ~ cast(ubyte[])([numMethods, numGetters, numSetters, numStatics]);

        if(clnode.classDefinition.baseClass)
            _baseClassStack = _baseClassStack[0..$-1];

        return Variant(null);
    }

    /// handles binary operations
    Variant visitBinaryOpNode(BinaryOpNode bonode)
    {
        if(bonode.opToken.isAssignmentOperator)
        {
            auto remade = reduceAssignment(bonode);
            handleAssignment(remade.leftNode, remade.opToken, remade.rightNode);
            return Variant(null);
        }
        else if(bonode.opToken.type == Token.Type.AND)
        {
            bonode.leftNode.accept(this);
            _chunk ~= OpCode.PUSH ~ encode!int(-1);
            _chunk ~= OpCode.NOT;
            immutable start = _chunk.length;
            immutable jmpFalse = genJmpFalse();
            immutable jumpOver = _chunk.length;
            immutable jmp = genJmp();
            immutable otherTrue = _chunk.length;
            _chunk ~= OpCode.POP;
            bonode.rightNode.accept(this);
            immutable end = _chunk.length;

            *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(otherTrue - start);
            *cast(int*)(_chunk.ptr + jmp) = cast(int)(end - jumpOver);
            return Variant(null);
        }
        else if(bonode.opToken.type == Token.Type.OR)
        {
            bonode.leftNode.accept(this);
            _chunk ~= OpCode.PUSH ~ encode!int(-1);
            immutable start = _chunk.length;
            immutable jmpFalse = genJmpFalse();
            immutable jumpOver = _chunk.length;
            immutable jmp = genJmp();
            immutable otherTrue = _chunk.length;
            _chunk ~= OpCode.POP;
            bonode.rightNode.accept(this);
            immutable end = _chunk.length;

            *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(otherTrue - start);
            *cast(int*)(_chunk.ptr + jmp) = cast(int)(end - jumpOver);
            return Variant(null);
        }
        else if(bonode.opToken.type == Token.Type.NULLC)
        {
            auto tern = new TerniaryOpNode(
                new BinaryOpNode(Token.createFakeToken(Token.Type.EQUALS, ""), 
                    bonode.leftNode, new LiteralNode(
                        Token.createFakeToken(Token.Type.KEYWORD, "null"), ScriptAny(null) )
                    ),
                bonode.rightNode, bonode.leftNode
            );
            tern.accept(this);
            return Variant(null);
        }

        // push operands
        bonode.leftNode.accept(this);
        bonode.rightNode.accept(this);
        switch(bonode.opToken.type)
        {
        case Token.Type.POW:
            _chunk ~= OpCode.POW;
            break;
        case Token.Type.STAR:
            _chunk ~= OpCode.MUL;
            break;
        case Token.Type.FSLASH:
            _chunk ~= OpCode.DIV;
            break;
        case Token.Type.PERCENT:
            _chunk ~= OpCode.MOD;
            break;
        case Token.Type.PLUS:
            _chunk ~= OpCode.ADD;
            break;
        case Token.Type.DASH:
            _chunk ~= OpCode.SUB;
            break;
        case Token.Type.BIT_RSHIFT:
            _chunk ~= OpCode.BITRSH;
            break;
        case Token.Type.BIT_URSHIFT:
            _chunk ~= OpCode.BITURSH;
            break;
        case Token.Type.BIT_LSHIFT:
            _chunk ~= OpCode.BITLSH;
            break;
        case Token.Type.LT:
            _chunk ~= OpCode.LT;
            break;
        case Token.Type.LE:
            _chunk ~= OpCode.LE;
            break;
        case Token.Type.GT:
            _chunk ~= OpCode.GT;
            break;
        case Token.Type.GE:
            _chunk ~= OpCode.GE;
            break;
        case Token.Type.EQUALS:
            _chunk ~= OpCode.EQUALS;
            break;
        case Token.Type.NEQUALS:
            _chunk ~= OpCode.NEQUALS;
            break;
        case Token.Type.STRICT_EQUALS:
            _chunk ~= OpCode.STREQUALS;
            break;
        case Token.Type.STRICT_NEQUALS:
            _chunk ~= OpCode.NSTREQUALS;
            break;
        case Token.Type.BIT_AND:
            _chunk ~= OpCode.BITAND;
            break;
        case Token.Type.BIT_OR:
            _chunk ~= OpCode.BITOR;
            break;
        case Token.Type.BIT_XOR:
            _chunk ~= OpCode.BITXOR;
            break;
        default:
            if(bonode.opToken.isKeyword("instanceof"))
                _chunk ~= OpCode.INSTANCEOF;
            else
                throw new Exception("Uncaught parser or compiler error: " ~ bonode.toString());
        }
        return Variant(null);
    }

    /// handle unary operations
    Variant visitUnaryOpNode(UnaryOpNode uonode)
    {
        switch(uonode.opToken.type)
        {
        case Token.Type.BIT_NOT:
            uonode.operandNode.accept(this);
            _chunk ~= OpCode.BITNOT;
            break;
        case Token.Type.NOT:
            uonode.operandNode.accept(this);
            _chunk ~= OpCode.NOT;
            break;
        case Token.Type.DASH:
            uonode.operandNode.accept(this);
            _chunk ~= OpCode.NEGATE;
            break;
        case Token.Type.PLUS:
            uonode.operandNode.accept(this);
            break;
        case Token.Type.INC: {
            if(!nodeIsAssignable(uonode.operandNode))
                throw new ScriptCompileException("Invalid operand for prefix operation", uonode.opToken);
            auto assignmentNode = reduceAssignment(new BinaryOpNode(Token.createFakeToken(Token.Type.PLUS_ASSIGN,""), 
                    uonode.operandNode, 
                    new LiteralNode(Token.createFakeToken(Token.Type.INTEGER, "1"), ScriptAny(1)))
            );
            handleAssignment(assignmentNode.leftNode, assignmentNode.opToken, assignmentNode.rightNode); 
            break;        
        }
        case Token.Type.DEC:
            if(!nodeIsAssignable(uonode.operandNode))
                throw new ScriptCompileException("Invalid operand for prefix operation", uonode.opToken);
            auto assignmentNode = reduceAssignment(new BinaryOpNode(Token.createFakeToken(Token.Type.DASH_ASSIGN,""), 
                    uonode.operandNode, 
                    new LiteralNode(Token.createFakeToken(Token.Type.INTEGER, "1"), ScriptAny(1)))
            );
            handleAssignment(assignmentNode.leftNode, assignmentNode.opToken, assignmentNode.rightNode);
            break;
        default:
            uonode.operandNode.accept(this);
            if(uonode.opToken.isKeyword("typeof"))
                _chunk ~= OpCode.TYPEOF;
            else
                throw new Exception("Uncaught parser error: " ~ uonode.toString());
        }
        return Variant(null);
    }

    /// Handle x++ and x--
    Variant visitPostfixOpNode(PostfixOpNode ponode)
    {
        if(!nodeIsAssignable(ponode.operandNode))
            throw new ScriptCompileException("Invalid operand for postfix operator", ponode.opToken);
        immutable incOrDec = ponode.opToken.type == Token.Type.INC ? 1 : -1;
        // first push the original value
        ponode.operandNode.accept(this);
        // generate an assignment
        auto assignmentNode = reduceAssignment(new BinaryOpNode(
            Token.createFakeToken(Token.Type.PLUS_ASSIGN, ""),
            ponode.operandNode,
            new LiteralNode(Token.createFakeToken(Token.Type.IDENTIFIER, "?"), ScriptAny(incOrDec))
        ));
        // process the assignment
        handleAssignment(assignmentNode.leftNode, assignmentNode.opToken, assignmentNode.rightNode);
        // pop the value of the assignment, leaving original value on stack
        _chunk ~= OpCode.POP;
        return Variant(null);
    }

    /// handle :? operator
    Variant visitTerniaryOpNode(TerniaryOpNode tonode)
    {
        tonode.conditionNode.accept(this);
        immutable start = _chunk.length;
        immutable jmpFalse =  genJmpFalse();
        tonode.onTrueNode.accept(this);
        immutable endTrue = _chunk.length;
        immutable jmp = genJmp();
        immutable falseLabel = _chunk.length;
        tonode.onFalseNode.accept(this);
        immutable end = _chunk.length;

        *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(falseLabel - start);
        *cast(int*)(_chunk.ptr + jmp) = cast(int)(end - endTrue);

        return Variant(null);
    }

    /// These should not be directly visited for assignment
    Variant visitVarAccessNode(VarAccessNode vanode)
    {
        if(varExists(vanode.varToken.text))
        {
            auto varMeta = lookupVar(vanode.varToken.text);
            if(varMeta.funcDepth == _funcDepth && varMeta.stackLocation != -1)
            {
                _chunk ~= OpCode.PUSH ~ encode!int(varMeta.stackLocation);
                return Variant(null);
            }
        }
        _chunk ~= OpCode.GETVAR ~ encodeConst(vanode.varToken.text);
        return Variant(null);
    }

    /// Handle function() calls
    Variant visitFunctionCallNode(FunctionCallNode fcnode)
    {
        // if returnThis is set this is an easy new op
        if(fcnode.returnThis)
        {
            fcnode.functionToCall.accept(this);
            foreach(argExpr ; fcnode.expressionArgs)
                argExpr.accept(this);
            _chunk ~= OpCode.NEW ~ encode!uint(cast(uint)fcnode.expressionArgs.length);
            return Variant(null);
        }
        else
        {
            // if a member access then the "this" must be set to left hand side
            if(auto man = cast(MemberAccessNode)fcnode.functionToCall)
            {
                if(!cast(SuperNode)man.objectNode)
                {
                    man.objectNode.accept(this); // first put object on stack
                    _chunk ~= OpCode.PUSH ~ encode!int(-1); // push it again
                    auto van = cast(VarAccessNode)man.memberNode;
                    if(van is null)
                        throw new ScriptCompileException("Invalid `.` operand", man.dotToken);
                    _chunk ~= OpCode.CONST ~ encodeConst(van.varToken.text);
                    _chunk ~= OpCode.OBJGET; // this places obj as this and the func on stack
                }
                else
                {
                    _chunk ~= OpCode.THIS;
                    fcnode.functionToCall.accept(this);
                }
            } // else if an array access same concept
            else if(auto ain = cast(ArrayIndexNode)fcnode.functionToCall)
            {
                if(!cast(SuperNode)ain.objectNode)
                {
                    ain.objectNode.accept(this);
                    _chunk ~= OpCode.PUSH ~ encode!int(-1); // push it again
                    ain.indexValueNode.accept(this);
                    _chunk ~= OpCode.OBJGET; // now the array and function are on stack
                }
                else
                {
                    _chunk ~= OpCode.THIS;
                    fcnode.functionToCall.accept(this);
                }
            }
            else // either a variable or literal function, pull this and function
            {
                _chunk ~= OpCode.THIS;
                fcnode.functionToCall.accept(this);
                if(cast(SuperNode)fcnode.functionToCall)
                {
                    // could be a super() constructor call
                    _chunk ~= OpCode.CONST ~ encodeConst("constructor");
                    _chunk ~= OpCode.OBJGET;
                }
            }
            foreach(argExpr ; fcnode.expressionArgs)
                argExpr.accept(this);
            _chunk ~= OpCode.CALL ~ encode!uint(cast(uint)fcnode.expressionArgs.length);
        }
        return Variant(null);
    }

    /// handle [] operator. This method cannot be used in assignment
    Variant visitArrayIndexNode(ArrayIndexNode ainode)
    {
        ainode.objectNode.accept(this);
        ainode.indexValueNode.accept(this);
        _chunk ~= OpCode.OBJGET;
        return Variant(null);
    }

    /// handle . operator. This method cannot be used in assignment
    Variant visitMemberAccessNode(MemberAccessNode manode)
    {
        manode.objectNode.accept(this);
        // memberNode has to be a var access node for this to make any sense
        auto van = cast(VarAccessNode)manode.memberNode;
        if(van is null)
            throw new ScriptCompileException("Invalid right operand for `.` operator", manode.dotToken);
        _chunk ~= OpCode.CONST ~ encodeConst(van.varToken.text);
        _chunk ~= OpCode.OBJGET;
        return Variant(null);
    }

    /// handle new operator. visitFunctionCallExpression will handle returnThis field
    Variant visitNewExpressionNode(NewExpressionNode nenode)
    {
        nenode.functionCallExpression.accept(this);
        return Variant(null);
    }

    /// this should only be directly visited when used by itself
    Variant visitSuperNode(SuperNode snode)
    {
        _chunk ~= OpCode.THIS;
        _chunk ~= OpCode.CONST ~ encodeConst("__super__");
        _chunk ~= OpCode.OBJGET;
        return Variant(null);
    }

    /// handle yield statements.
    Variant visitYieldNode(YieldNode ynode)
    {
        // it's just a function call to yield
        _chunk ~= OpCode.STACK_1; // disregard this
        _chunk ~= OpCode.GETVAR ~ encodeConst("yield");
        if(ynode.yieldExpression)
            ynode.yieldExpression.accept(this);
        else
            _chunk ~= OpCode.STACK_1;
        _chunk ~= OpCode.CALL ~ encode!uint(1);
        return Variant(null);
    }
    
    /// Handle var declaration
    Variant visitVarDeclarationStatementNode(VarDeclarationStatementNode vdsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, vdsnode.line);
        foreach(expr ; vdsnode.varAccessOrAssignmentNodes)
        {
            string varName = "";
            DestructureTargetNode destr = null;

            // is it a validated binop node
            if(auto bopnode = cast(BinaryOpNode)expr)
            {
                // if the right hand side is a function literal, we can rename it
                if(auto flnode = cast(FunctionLiteralNode)bopnode.rightNode)
                {
                    if(flnode.optionalName == "")
                        flnode.optionalName = bopnode.leftNode.toString();
                }
                else if(auto clsnode = cast(ClassLiteralNode)bopnode.rightNode)
                {
                    if(clsnode.classDefinition.className == "<anonymous class>")
                    {
                        clsnode.classDefinition.constructor.optionalName = bopnode.leftNode.toString();
                        clsnode.classDefinition.className = bopnode.leftNode.toString();
                    }
                }
                if(auto destru = cast(DestructureTargetNode)bopnode.leftNode)
                {
                    bopnode.rightNode.accept(this);
                    destr = destru;
                }
                else 
                {
                    auto van = cast(VarAccessNode)bopnode.leftNode;
                    bopnode.rightNode.accept(this); // push value to stack
                    varName = van.varToken.text;
                }
            }
            else if(auto van = cast(VarAccessNode)expr)
            {
                _chunk ~= OpCode.STACK_1; // push undefined
                varName = van.varToken.text;
            }
            else
                throw new Exception("Parser failure or unimplemented feature: " ~ vdsnode.toString());

            if(vdsnode.qualifier.text != "var" && vdsnode.qualifier.text != "let" && vdsnode.qualifier.text != "const")
                throw new Exception("Parser failed to parse variable declaration");

            if(destr)
            {
                for(size_t i = 0; i < destr.varNames.length; ++i)
                {
                    _chunk ~= OpCode.PUSH ~ encode!int(-1);
                    if(destr.isObject)
                        _chunk ~= OpCode.CONST ~ encodeConst(destr.varNames[i]);
                    else
                        _chunk ~= OpCode.CONST ~ encodeConst(i);
                    _chunk ~= OpCode.OBJGET;
                    if(vdsnode.qualifier.text == "var")
                        _chunk ~= OpCode.DECLVAR ~ encodeConst(destr.varNames[i]);
                    else if(vdsnode.qualifier.text == "let")
                        _chunk ~= OpCode.DECLLET ~ encodeConst(destr.varNames[i]);
                    else if(vdsnode.qualifier.text == "const")
                        _chunk ~= OpCode.DECLCONST ~ encodeConst(destr.varNames[i]);
                }
                if(destr.remainderName)
                {
                    if(!destr.isObject)
                    {
                        _chunk ~= OpCode.PUSH ~ encode!int(-1);
                        _chunk ~= OpCode.CONST ~ encodeConst("slice");
                        _chunk ~= OpCode.OBJGET;
                        _chunk ~= OpCode.CONST ~ encodeConst(destr.varNames.length);
                        _chunk ~= OpCode.CALL ~ encode!uint(1);
                    }
                    if(vdsnode.qualifier.text == "var")
                        _chunk ~= OpCode.DECLVAR ~ encodeConst(destr.remainderName);
                    else if(vdsnode.qualifier.text == "let")
                        _chunk ~= OpCode.DECLLET ~ encodeConst(destr.remainderName);
                    else if(vdsnode.qualifier.text == "const")
                        _chunk ~= OpCode.DECLCONST ~ encodeConst(destr.remainderName);
                }
                else
                {
                    _chunk ~= OpCode.POP;
                }
            }
            else
            {
                if(vdsnode.qualifier.text == "var")
                    _chunk ~= OpCode.DECLVAR ~ encodeConst(varName);
                else if(vdsnode.qualifier.text == "let")
                    _chunk ~= OpCode.DECLLET ~ encodeConst(varName);
                else if(vdsnode.qualifier.text == "const")
                    _chunk ~= OpCode.DECLCONST ~ encodeConst(varName);
            }
        }
        return Variant(null);
    }

    /// handle {} braces
    Variant visitBlockStatementNode(BlockStatementNode bsnode)
    {
        import std.conv: to;
        _debugInfoStack.top.addLine(_chunk.length, bsnode.line);
        // if there are no declarations at the top level the scope op can be omitted
        bool omitScope = true;
        foreach(stmt ; bsnode.statementNodes)
        {
            if(cast(VarDeclarationStatementNode)stmt
            || cast(FunctionDeclarationStatementNode)stmt 
            || cast(ClassDeclarationStatementNode)stmt)
            {
                omitScope = false;
                break;
            }
        }
        if(!omitScope)
        {
            ++_compDataStack.top.depthCounter;
            _compDataStack.top.stackVariables.push(VarTable.init);

            _chunk ~= OpCode.OPENSCOPE;
        }
        foreach(stmt ; bsnode.statementNodes)
            stmt.accept(this);
        
        if(!omitScope)
        {
            _chunk ~= OpCode.CLOSESCOPE;

            _compDataStack.top.stackVariables.pop();
            --_compDataStack.top.depthCounter;
        }
        return Variant(null);
    }

    /// emit if statements
    Variant visitIfStatementNode(IfStatementNode isnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, isnode.line);
        isnode.onTrueStatement = new BlockStatementNode(isnode.onTrueStatement.line, [isnode.onTrueStatement]);
        if(isnode.onFalseStatement)
            isnode.onFalseStatement = new BlockStatementNode(isnode.onFalseStatement.line, [isnode.onFalseStatement]);
        if(isnode.onFalseStatement)
        {
            if(cast(VarDeclarationStatementNode)isnode.onFalseStatement)
                isnode.onFalseStatement = new BlockStatementNode(isnode.onFalseStatement.line, 
                        [isnode.onFalseStatement]);
        }
        isnode.conditionNode.accept(this);
        auto length = cast(int)_chunk.length;
        auto jmpFalseToPatch = genJmpFalse();
        isnode.onTrueStatement.accept(this);
        auto length2 = cast(int)_chunk.length;
        auto jmpOverToPatch = genJmp();
        *cast(int*)(_chunk.ptr + jmpFalseToPatch) = cast(int)_chunk.length - length;
        length = cast(int)_chunk.length;
        if(isnode.onFalseStatement !is null)
        {
            isnode.onFalseStatement.accept(this);
        }
        *cast(int*)(_chunk.ptr + jmpOverToPatch) = cast(int)_chunk.length - length2;

        return Variant(null);
    }

    /// Switch statements
    Variant visitSwitchStatementNode(SwitchStatementNode ssnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, ssnode.line);

        size_t[ScriptAny] unpatchedJumpTbl;
        size_t statementCounter = 0;        
        
        ++_compDataStack.top.loopOrSwitchStack;
        // generate unpatched jump array
        foreach(key, value ; ssnode.switchBody.jumpTable)
        {
            unpatchedJumpTbl[key] = genJmpTableEntry(key);
        }
        _chunk ~= OpCode.ARRAY ~ encode!uint(cast(uint)ssnode.switchBody.jumpTable.length);
        // generate expression to test
        ssnode.expressionNode.accept(this);
        // generate switch statement
        immutable unpatchedSwitchParam = genSwitchStatement();
        bool patched = false;
        // generate each statement, patching along the way
        ++_compDataStack.top.depthCounter;
        _compDataStack.top.stackVariables.push(VarTable.init);
        _chunk ~= OpCode.OPENSCOPE;
        foreach(stmt ; ssnode.switchBody.statementNodes)
        {
            uint patchData = cast(uint)_chunk.length;
            foreach(k, v ; ssnode.switchBody.jumpTable)
            {
                if(v == statementCounter)
                {
                    immutable ptr = unpatchedJumpTbl[k];
                    _chunk[ptr .. ptr + 4] = encodeConst(patchData)[0..4];
                }
            }
            // could also be default in which case we patch the switch
            if(statementCounter == ssnode.switchBody.defaultStatementID)
            {
                *cast(uint*)(_chunk.ptr + unpatchedSwitchParam) = patchData;
                patched = true;
            }
            stmt.accept(this);
            ++statementCounter;
        }
        _chunk ~= OpCode.CLOSESCOPE;
        _compDataStack.top.stackVariables.pop();
        --_compDataStack.top.depthCounter;
        immutable breakLocation = _chunk.length;
        if(!patched)
        {
            *cast(uint*)(_chunk.ptr + unpatchedSwitchParam) = cast(uint)breakLocation;
        }
        --_compDataStack.top.loopOrSwitchStack;

        patchBreaksAndContinues("", breakLocation, breakLocation, _compDataStack.top.depthCounter, 
                _compDataStack.top.loopOrSwitchStack);
        removePatches();

        return Variant(null);
    }

    /// Handle while loops
    Variant visitWhileStatementNode(WhileStatementNode wsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, wsnode.line);
        ++_compDataStack.top.loopOrSwitchStack;
        immutable length0 = _chunk.length;
        immutable continueLocation = length0;
        wsnode.conditionNode.accept(this);
        immutable length1 = _chunk.length;
        immutable jmpFalse = genJmpFalse();
        wsnode.bodyNode.accept(this);
        immutable length2 = _chunk.length;
        immutable jmp = genJmp();
        immutable breakLocation = _chunk.length;
        *cast(int*)(_chunk.ptr + jmp) = -cast(int)(length2 - length0);
        *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(_chunk.length - length1);
        // patch gotos
        patchBreaksAndContinues(wsnode.label, breakLocation, continueLocation,
                _compDataStack.top.depthCounter, _compDataStack.top.loopOrSwitchStack);
        --_compDataStack.top.loopOrSwitchStack;
        removePatches();
        return Variant(null);
    }

    /// do-while loops
    Variant visitDoWhileStatementNode(DoWhileStatementNode dwsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, dwsnode.line);
        ++_compDataStack.top.loopOrSwitchStack;
        immutable doWhile = _chunk.length;
        dwsnode.bodyNode.accept(this);
        immutable continueLocation = _chunk.length;
        dwsnode.conditionNode.accept(this);
        _chunk ~= OpCode.NOT;
        immutable whileCondition = _chunk.length;
        immutable jmpFalse = genJmpFalse();
        *cast(int*)(_chunk.ptr + jmpFalse) = -cast(int)(whileCondition - doWhile);
        immutable breakLocation = _chunk.length;
        patchBreaksAndContinues(dwsnode.label, breakLocation, continueLocation, _compDataStack.top.depthCounter,
                _compDataStack.top.loopOrSwitchStack);
        --_compDataStack.top.loopOrSwitchStack;
        removePatches();
        return Variant(null);
    }

    /// handle regular for loops
    Variant visitForStatementNode(ForStatementNode fsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, fsnode.line);
        ++_compDataStack.top.loopOrSwitchStack;
        // set up stack variables
        // handleStackDeclaration(fsnode.varDeclarationStatement);
        ++_compDataStack.top.depthCounter;
        _chunk ~= OpCode.OPENSCOPE;
        if(fsnode.varDeclarationStatement)
            fsnode.varDeclarationStatement.accept(this);
        immutable length0 = _chunk.length;
        fsnode.conditionNode.accept(this);
        immutable length1 = _chunk.length;
        immutable jmpFalse = genJmpFalse();
        fsnode.bodyNode.accept(this);
        immutable continueLocation = _chunk.length;
        // increment is a single expression not a statement so we must add a pop
        fsnode.incrementNode.accept(this);
        _chunk ~= OpCode.POP;
        immutable length2 = _chunk.length;
        immutable jmp = genJmp();
        immutable breakLocation = _chunk.length;
        // handleStackCleanup(fsnode.varDeclarationStatement);
        _chunk ~= OpCode.CLOSESCOPE;
        // patch jmps
        *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(breakLocation - length1);
        *cast(int*)(_chunk.ptr + jmp) = -cast(int)(length2 - length0);
        patchBreaksAndContinues(fsnode.label, breakLocation, continueLocation, _compDataStack.top.depthCounter,
                _compDataStack.top.loopOrSwitchStack);
        --_compDataStack.top.loopOrSwitchStack;
        --_compDataStack.top.depthCounter;
        removePatches();
        return Variant(null);
    }

    /// Visit for-of statements
    Variant visitForOfStatementNode(ForOfStatementNode fosnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, fosnode.line);
        string[] varNames;
        foreach(van ; fosnode.varAccessNodes)
            varNames ~= van.varToken.text;
        fosnode.objectToIterateNode.accept(this);
        _chunk ~= OpCode.ITER;
        ++_stackVarCounter;
        _chunk ~= OpCode.STACK_1;
        _chunk ~= OpCode.PUSH ~ encode!int(-2);
        _chunk ~= OpCode.CALL ~ encode!uint(0);
        _chunk ~= OpCode.PUSH ~ encode!int(-1);
        ++_stackVarCounter;
        ++_compDataStack.top.forOfDepth;
        _chunk ~= OpCode.CONST ~ encodeConst("done");
        _chunk ~= OpCode.OBJGET;
        _chunk ~= OpCode.NOT;
        immutable loop = _chunk.length;
        immutable jmpFalse = genJmpFalse();
        _chunk ~= OpCode.OPENSCOPE;
        if(varNames.length == 1)
        {
            _chunk ~= OpCode.PUSH ~ encode!int(-1);
            _chunk ~= OpCode.CONST ~ encodeConst("value");
            _chunk ~= OpCode.OBJGET;
            _chunk ~= (fosnode.qualifierToken.text == "let" ? OpCode.DECLLET : OpCode.DECLCONST)
                ~ encodeConst(varNames[0]);
        }
        else if(varNames.length == 2)
        {
            _chunk ~= OpCode.PUSH ~ encode!int(-1);
            _chunk ~= OpCode.CONST ~ encodeConst("key");
            _chunk ~= OpCode.OBJGET;
            _chunk ~= (fosnode.qualifierToken.text == "let" ? OpCode.DECLLET : OpCode.DECLCONST)
                ~ encodeConst(varNames[0]);
            _chunk ~= OpCode.PUSH ~ encode!int(-1);
            _chunk ~= OpCode.CONST ~ encodeConst("value");
            _chunk ~= OpCode.OBJGET;
            _chunk ~= (fosnode.qualifierToken.text == "let" ? OpCode.DECLLET : OpCode.DECLCONST)
                ~ encodeConst(varNames[1]);
        }
        ++_compDataStack.top.loopOrSwitchStack;
        fosnode.bodyNode.accept(this);
        immutable continueLocation = _chunk.length;
        _chunk ~= OpCode.POP;
        _chunk ~= OpCode.STACK_1;
        _chunk ~= OpCode.PUSH ~ encode!int(-2);
        _chunk ~= OpCode.CALL ~ encode!uint(0);
        _chunk ~= OpCode.PUSH ~ encode!int(-1);
        _chunk ~= OpCode.CONST ~ encodeConst("done");
        _chunk ~= OpCode.OBJGET;
        _chunk ~= OpCode.NOT;
        _chunk ~= OpCode.CLOSESCOPE;
        immutable loopAgain = _chunk.length;
        immutable jmp = genJmp();
        *cast(int*)(_chunk.ptr + jmp) = -cast(int)(loopAgain - loop);
        immutable breakLocation = _chunk.length;
        _chunk ~= OpCode.CLOSESCOPE;
        immutable endLoop = _chunk.length;
        _chunk ~= OpCode.POPN ~ encode!uint(2);
        --_compDataStack.top.forOfDepth;
        _stackVarCounter -= 2;
        *cast(int*)(_chunk.ptr + jmpFalse) = cast(int)(endLoop - loop);
        patchBreaksAndContinues(fosnode.label, breakLocation, continueLocation, 
                _compDataStack.top.depthCounter, _compDataStack.top.loopOrSwitchStack);
        --_compDataStack.top.loopOrSwitchStack;
        removePatches();
        return Variant(null);
    }

    /// visit break statements
    Variant visitBreakStatementNode(BreakStatementNode bsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, bsnode.line);
        immutable patchLocation = _chunk.length + 1;
        _chunk ~= OpCode.GOTO ~ encode(uint.max) ~ cast(ubyte)0;
        _compDataStack.top.breaksToPatch ~= BreakOrContinueToPatch(bsnode.label, patchLocation,
                _compDataStack.top.depthCounter, _compDataStack.top.loopOrSwitchStack);
        return Variant(null);
    }

    /// visit continue statements
    Variant visitContinueStatementNode(ContinueStatementNode csnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, csnode.line);
        immutable patchLocation = _chunk.length + 1;
        _chunk ~= OpCode.GOTO ~ encode(uint.max - 1) ~ cast(ubyte)0;
        _compDataStack.top.continuesToPatch ~= BreakOrContinueToPatch(csnode.label, patchLocation,
                _compDataStack.top.depthCounter, _compDataStack.top.loopOrSwitchStack);
        return Variant(null);
    }

    /// Return statements
    Variant visitReturnStatementNode(ReturnStatementNode rsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, rsnode.line);
        immutable numPops = _compDataStack.top.forOfDepth * 2;
        if(numPops == 1)
            _chunk ~= OpCode.POP;
        else if(numPops > 1)
            _chunk ~= OpCode.POPN ~ encode!uint(numPops);
        if(rsnode.expressionNode !is null)
            rsnode.expressionNode.accept(this);
        else
            _chunk ~= OpCode.STACK_1;
        _chunk ~= OpCode.RETURN;
        return Variant(null);
    }

    /// function declarations
    Variant visitFunctionDeclarationStatementNode(FunctionDeclarationStatementNode fdsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, fdsnode.line);
        // easy, reduce it to a let fname = function(){...} VarDeclarationStatement
        auto vdsn = new VarDeclarationStatementNode(
            fdsnode.line,
            Token.createFakeToken(Token.Type.KEYWORD, "let"), [
                new BinaryOpNode(
                    Token.createFakeToken(Token.Type.ASSIGN, ""),
                    new VarAccessNode(Token.createFakeToken(Token.Type.IDENTIFIER, fdsnode.name)),
                    new FunctionLiteralNode(
                        Token(Token.Type.KEYWORD, Position(cast(int)fdsnode.line, 1)),
                        fdsnode.argNames, fdsnode.defaultArguments,
                        fdsnode.statementNodes, fdsnode.name, false, fdsnode.isGenerator
                    )
                )
            ]
        );
        vdsn.accept(this);
        return Variant(null);
    }

    /// Throw statement
    Variant visitThrowStatementNode(ThrowStatementNode tsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, tsnode.line);
        tsnode.expressionNode.accept(this);
        _chunk ~= OpCode.THROW;
        return Variant(null);
    }

    /// Try catch
    Variant visitTryCatchBlockStatementNode(TryCatchBlockStatementNode tcbsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, tcbsnode.line);
        // emit try block
        immutable tryToPatch = genTry();
        tcbsnode.tryBlockNode.accept(this);
        _chunk ~= OpCode.ENDTRY;
        immutable length0 = cast(int)_chunk.length;
        immutable jmpToPatch = genJmp();
        *cast(uint*)(_chunk.ptr + tryToPatch) = cast(uint)_chunk.length;
        // emit catch block
        immutable omitScope = tcbsnode.exceptionName == ""? true: false;
        if(!omitScope)
        {
            ++_compDataStack.top.depthCounter;
            _compDataStack.top.stackVariables.push(VarTable.init);
            _chunk ~= OpCode.OPENSCOPE;
        }
        if(tcbsnode.catchBlockNode)
        {
            _chunk ~= OpCode.LOADEXC;
            if(!omitScope)
                _chunk ~= OpCode.DECLLET ~ encodeConst(tcbsnode.exceptionName);
            else
                _chunk ~= OpCode.POP;
            tcbsnode.catchBlockNode.accept(this);
        }
        if(!omitScope)
        {
            --_compDataStack.top.depthCounter;
            _compDataStack.top.stackVariables.pop();
            _chunk ~= OpCode.CLOSESCOPE;
        }
        *cast(int*)(_chunk.ptr + jmpToPatch) = cast(int)_chunk.length - length0;
        // emit finally block
        if(tcbsnode.finallyBlockNode)
        {
            tcbsnode.finallyBlockNode.accept(this);
            if(tcbsnode.catchBlockNode is null)
                _chunk ~= OpCode.RETHROW;
        }
        return Variant(null);
    }

    /// delete statement. can be used on ArrayIndexNode or MemberAccessNode
    Variant visitDeleteStatementNode(DeleteStatementNode dsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, dsnode.line);
        if(auto ain = cast(ArrayIndexNode)dsnode.memberAccessOrArrayIndexNode)
        {
            ain.objectNode.accept(this);
            ain.indexValueNode.accept(this);
        }
        else if(auto man = cast(MemberAccessNode)dsnode.memberAccessOrArrayIndexNode)
        {
            man.objectNode.accept(this);
            auto van = cast(VarAccessNode)man.memberNode;
            if(van is null)
                throw new Exception("Parser failure in delete statement");
            _chunk ~= OpCode.CONST ~ encodeConst(van.varToken.text);
        }
        else
            throw new ScriptCompileException("Invalid operand to delete", dsnode.deleteToken);
        _chunk ~= OpCode.DEL;
        return Variant(null);
    }

    /// Class declarations. Reduce to let leftHand = classExpression
    Variant visitClassDeclarationStatementNode(ClassDeclarationStatementNode cdsnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, cdsnode.line);
        auto reduction = new VarDeclarationStatementNode(
            Token.createFakeToken(Token.Type.KEYWORD, "let"),
            [
                new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, "="),
                    new VarAccessNode(Token.createFakeToken(Token.Type.IDENTIFIER, cdsnode.classDefinition.className)),
                    new ClassLiteralNode(cdsnode.classToken, cdsnode.classDefinition))
            ]);
        reduction.accept(this);
        return Variant(null);
    }

    /// handle expression statements
    Variant visitExpressionStatementNode(ExpressionStatementNode esnode)
    {
        _debugInfoStack.top.addLine(_chunk.length, esnode.line);
        if(esnode.expressionNode is null)
            return Variant(null);
        esnode.expressionNode.accept(this);
        _chunk ~= OpCode.POP;
        return Variant(null);
    }

private:
    static const int UNPATCHED_JMP = 262_561_909;
    static const uint UNPATCHED_JMPENTRY = 3_735_890_861;
    static const uint UNPATCHED_TRY_GOTO = uint.max;

    size_t addStackVar(string name, bool isConst)
    {
        size_t id = _stackVarCounter++;
        defineVar(name, VarMetadata(true, cast(int)id, cast(int)_funcDepth, isConst));
        return id;
    }

    void defineVar(string name, VarMetadata vmeta)
    {
        _compDataStack.top.stackVariables.top[name] = vmeta;
    }

    ubyte[] encodeConst(T)(T value)
    {
        return encode(_constTable.addValueUint(ScriptAny(value)));
    }

    ubyte[] encodeConst(T : ScriptAny)(T value)
    {
        return encode(_constTable.addValueUint(value));
    }

    /// The return value MUST BE USED
    size_t genSwitchStatement()
    {
        immutable switchParam = _chunk.length + 1;
        _chunk ~= OpCode.SWITCH ~ encode!uint(UNPATCHED_JMPENTRY);
        return switchParam;
    }

    /// The return value MUST BE USED
    size_t genJmp()
    {
        _chunk ~= OpCode.JMP ~ encode!int(UNPATCHED_JMP);
        return _chunk.length - int.sizeof;
    }

    /// The return value MUST BE USED
    size_t genJmpFalse()
    {
        _chunk ~= OpCode.JMPFALSE ~ encode!int(UNPATCHED_JMP);
        return _chunk.length - int.sizeof;
    }

    /// The return value MUST BE USED
    size_t genJmpTableEntry(ScriptAny value)
    {
        _chunk ~= OpCode.CONST ~ encodeConst(value);
        immutable constEntry = _chunk.length + 1;
        _chunk ~= OpCode.CONST ~ encode!uint(UNPATCHED_JMPENTRY);
        _chunk ~= OpCode.ARRAY ~ encode!uint(2);
        return constEntry;
    }

    /// The return value MUST BE USED
    size_t genTry()
    {
        _chunk ~= OpCode.TRY ~ encode!uint(uint.max);
        return _chunk.length - uint.sizeof;
    }

    void handleAssignment(ExpressionNode leftExpr, Token opToken, ExpressionNode rightExpr)
    {
        // in case we are assigning to object access expressions
        if(auto classExpr = cast(ClassLiteralNode)rightExpr)
        {
            if(classExpr.classDefinition.className == ""
            || classExpr.classDefinition.className == "<anonymous class>")
                classExpr.classDefinition.constructor.optionalName = leftExpr.toString();
        }
        else if(auto funcLit = cast(FunctionLiteralNode)rightExpr)
        {
            if(funcLit.optionalName == "" || funcLit.optionalName == "<anonymous function>")
                funcLit.optionalName = leftExpr.toString();
        }
        if(auto van = cast(VarAccessNode)leftExpr)
        {
            rightExpr.accept(this);
            if(varExists(van.varToken.text))
            {
                bool isConst; // @suppress(dscanner.suspicious.unmodified)
                immutable varMeta = cast(immutable)lookupVar(van.varToken.text);
                if(varMeta.stackLocation != -1)
                {
                    if(varMeta.isConst)
                        throw new ScriptCompileException("Cannot reassign stack const " ~ van.varToken.text, 
                                van.varToken);
                    _chunk ~= OpCode.SET ~ encode!uint(cast(uint)varMeta.stackLocation);
                    return;
                }
            }
            _chunk ~= OpCode.SETVAR ~ encodeConst(van.varToken.text);
        }
        else if(auto man = cast(MemberAccessNode)leftExpr)
        {
            man.objectNode.accept(this);
            auto van = cast(VarAccessNode)man.memberNode;
            _chunk ~= OpCode.CONST ~ encodeConst(van.varToken.text);
            rightExpr.accept(this);
            _chunk ~= OpCode.OBJSET;
        }
        else if(auto ain = cast(ArrayIndexNode)leftExpr)
        {
            ain.objectNode.accept(this);
            ain.indexValueNode.accept(this);
            rightExpr.accept(this);
            _chunk ~= OpCode.OBJSET;
        }
        else
            throw new Exception("Another parser fail");
    }

    void handleStackCleanup(VarDeclarationStatementNode vdsnode)
    {
        if(vdsnode is null)
            return;
        uint numToPop = 0;
        foreach(node ; vdsnode.varAccessOrAssignmentNodes)
        {
            ++numToPop;
        }
        if(numToPop == 1)
            _chunk ~= OpCode.POP;
        else
            _chunk ~= OpCode.POPN ~ encode!uint(numToPop);
        _stackVarCounter -= numToPop;
        _counterStack.pop();
        _compDataStack.top.stackVariables.pop();
    }

    void handleStackDeclaration(VarDeclarationStatementNode vdsnode)
    {
        if(vdsnode is null)
            return;
        _compDataStack.top.stackVariables.push(VarTable.init);
        foreach(node ; vdsnode.varAccessOrAssignmentNodes)
        {
            if(auto bopnode = cast(BinaryOpNode)node)
            {
                if(bopnode.opToken.type != Token.Type.ASSIGN)
                    throw new ScriptCompileException("Invalid declaration in for loop", bopnode.opToken);
                auto van = cast(VarAccessNode)bopnode.leftNode;
                auto id = addStackVar(van.varToken.text, vdsnode.qualifier.text == "const");
                _chunk ~= OpCode.STACK_1;
                bopnode.rightNode.accept(this);
                _chunk ~= OpCode.SET ~ encode!int(cast(int)id);
                _chunk ~= OpCode.POP;
            }
            else if(auto van = cast(VarAccessNode)node)
            {
                addStackVar(van.varToken.text, vdsnode.qualifier.text == "const");
                _chunk ~= OpCode.STACK_1;
            }
            else
                throw new Exception("Not sure what happened here");
        }
        _counterStack.push(_stackVarCounter);
    }

    VarMetadata lookupVar(string name)
    {
        for(auto n = _compDataStack.size; n > 0; --n)
        {
            for(auto i = 0; i < _compDataStack.array[n-1].stackVariables.array.length; ++i)
            {
                if(name in _compDataStack.array[n-1].stackVariables.array[$-i-1])
                    return _compDataStack.array[n-1].stackVariables.array[$-i-1][name];
            }
        }
        return VarMetadata(false, -1, 0, false);
    }

    bool nodeIsAssignable(ExpressionNode node)
    {
        if(cast(VarAccessNode)node)
            return true;
        if(cast(ArrayIndexNode)node)
            return true;
        if(cast(MemberAccessNode)node)
            return true;
        return false;
    }

    void patchBreaksAndContinues(string label, size_t breakGoto, size_t continueGoto, int depthCounter, int loopLevel)
    {
        for(size_t i = 0; i < _compDataStack.top.breaksToPatch.length; ++i)
        {
            BreakOrContinueToPatch* brk = &_compDataStack.top.breaksToPatch[i];
            if(!brk.patched)
            {
                if((brk.labelName == label) || (brk.labelName == "" && brk.loopLevel == loopLevel))
                {
                    *cast(uint*)(_chunk.ptr + brk.gotoPatchParam) = cast(uint)breakGoto;
                    immutable depthSize = brk.depth - depthCounter;
                    if(depthSize > ubyte.max)
                        throw new ScriptCompileException("Break depth exceeds ubyte.max",
                            Token.createFakeToken(Token.Type.KEYWORD, "break"));
                    _chunk[brk.gotoPatchParam + uint.sizeof] = cast(ubyte)depthSize;
                    brk.patched = true;
                }
            }
        }

        for(size_t i = 0; i < _compDataStack.top.continuesToPatch.length; ++i)
        {
            BreakOrContinueToPatch* cont = &_compDataStack.top.continuesToPatch[i];
            if(!cont.patched)
            {
                if((cont.labelName == label) || (cont.labelName == "" && cont.loopLevel == loopLevel))
                {
                    *cast(uint*)(_chunk.ptr + cont.gotoPatchParam) = cast(uint)continueGoto;
                    immutable depthSize = cont.depth - depthCounter;
                    if(depthSize > ubyte.max)
                        throw new ScriptCompileException("Continue depth exceeds ubyte.max",
                            Token.createFakeToken(Token.Type.KEYWORD, "continue"));
                    _chunk[cont.gotoPatchParam + uint.sizeof] = cast(ubyte)depthSize;
                    cont.patched = true;
                }
            }
        }

    }

    BinaryOpNode reduceAssignment(BinaryOpNode original)
    {
        switch(original.opToken.type)
        {
        case Token.Type.ASSIGN:
            return original; // nothing to do
        case Token.Type.POW_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.POW,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.STAR_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.STAR,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.FSLASH_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.FSLASH,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.PERCENT_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.PERCENT,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.PLUS_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.PLUS,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.DASH_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.DASH,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BAND_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_AND,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BXOR_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_XOR,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BOR_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_OR,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BLS_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_LSHIFT,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BRS_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_RSHIFT,""),
                            original.leftNode, original.rightNode)
            );
        case Token.Type.BURS_ASSIGN:
            return new BinaryOpNode(Token.createFakeToken(Token.Type.ASSIGN, ""), 
                    original.leftNode, 
                    new BinaryOpNode(Token.createFakeToken(Token.Type.BIT_URSHIFT,""),
                            original.leftNode, original.rightNode)
            );
        default:
            throw new Exception("Misuse of reduce assignment");
        }
    }

    void removePatches()
    {
        if(_compDataStack.top.loopOrSwitchStack == 0)
        {
            bool unresolved = false;
            if(_compDataStack.top.loopOrSwitchStack == 0)
            {
                foreach(brk ; _compDataStack.top.breaksToPatch)
                {
                    if(!brk.patched)
                    {
                        unresolved = true;
                        break;
                    }
                }

                foreach(cont ; _compDataStack.top.continuesToPatch)
                {
                    if(!cont.patched)
                    {
                        unresolved = true;
                        break;
                    }
                }
            }
            if(unresolved)
                throw new ScriptCompileException("Unresolvable break or continue statement", 
                        Token.createInvalidToken(Position(0,0), "break/continue"));
            _compDataStack.top.breaksToPatch = [];
            _compDataStack.top.continuesToPatch = [];
        }
    }

    void throwUnimplemented(ExpressionNode expr)
    {
        throw new UnimplementedException("Unimplemented: " ~ expr.toString());
    }

    void throwUnimplemented(StatementNode stmt)
    {
        throw new UnimplementedException("Unimplemented: " ~ stmt.toString());
    }

    bool varExists(string name)
    {
        for(auto n = _compDataStack.size; n > 0; --n)
        {
            for(auto i = 1; i <= _compDataStack.array[n-1].stackVariables.array.length; ++i)
            {
                if(name in _compDataStack.array[n-1].stackVariables.array[$-i])
                    return true;
            }
        }
        return false;
    }

    struct CompilationData
    {
        /// environment depth counter
        int depthCounter;
        /// how many loops nested
        int loopOrSwitchStack = 0;
        /// list of breaks needing patched
        BreakOrContinueToPatch[] breaksToPatch;
        /// list of continues needing patched
        BreakOrContinueToPatch[] continuesToPatch;

        /// holds stack variables
        Stack!VarTable stackVariables;
        
        /// for-of depth (this allocated 2 stack slots)
        int forOfDepth;
    }

    struct BreakOrContinueToPatch
    {
        this(string lbl, size_t param, int d, int ll)
        {
            labelName = lbl;
            gotoPatchParam = param;
            depth = d;
            loopLevel = ll;
        }
        string labelName;
        size_t gotoPatchParam;
        int depth;
        int loopLevel;
        bool patched = false;
    }

    struct VarMetadata
    {
        bool isDefined;
        int stackLocation; // can be -1 for regular lookup
        int funcDepth; // how deep in function calls
        bool isConst;
        VarDeclarationStatementNode varDecls;
    }

    alias VarTable = VarMetadata[string];

    /// when parsing a class expression or statement, if there is a base class it is added and poppped
    /// so that super expressions can be processed
    ExpressionNode[] _baseClassStack;

    /// the bytecode being compiled
    ubyte[] _chunk;
    ConstTable _constTable;
    DebugMap _debugMap;

    /// current source to send to each debugInfo
    string _currentSource;

    /// debug info stack
    Stack!DebugInfo _debugInfoStack;

    Stack!CompilationData _compDataStack;
    /**
     * The stack is guaranteed to be empty between statements so absolute stack positions for variables
     * can be used. The var name and stack ID is stored in the environment. The stack must be manually cleaned up
     */
    size_t _stackVarCounter = 0;
    /// keep track of function depth
    size_t _funcDepth;
    /// In case of a return statement in a for loop
    Stack!size_t _counterStack;
}

unittest
{
    import mildew.environment: Environment;
    auto compiler = new Compiler();
    auto program = compiler.compile("5 == 5 ? 'ass' : 'titties';"); // @suppress(dscanner.suspicious.unmodified)
    /*auto vm = new VirtualMachine(new Environment(null, "<global>"));
    vm.printProgram(program); // This all has to be done through an Interpreter instance
    vm.runProgram(program, []);*/ 
}