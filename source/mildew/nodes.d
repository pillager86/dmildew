/**
 * This module implements the expression and statement node subclasses, which are used internally as a syntax tree.
 */
module mildew.nodes;

import std.format: format;
import std.variant;

import mildew.context: Context;
import mildew.exceptions: ScriptRuntimeException;
import mildew.lexer: Token;
import mildew.types;
import mildew.visitors;

package:

/// root class of expression nodes
abstract class ExpressionNode
{
	abstract Variant accept(IExpressionVisitor visitor);

    // have to override here for subclasses' override to work
    override string toString() const
    {
        assert(false, "This should never be called as it is virtual");
    }
}

class LiteralNode : ExpressionNode 
{
    this(Token token, ScriptAny val)
    {
        literalToken = token;
        value = val;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitLiteralNode(this);
	}

    override string toString() const
    {
        if(value.type == ScriptAny.Type.STRING)
            return "\"" ~ literalToken.text ~ "\"";
        else
            return literalToken.text;
    }

    Token literalToken;
    ScriptAny value;
}

class FunctionLiteralNode : ExpressionNode
{
    this(string[] args, StatementNode[] stmts)
    {
        argList = args;
        statements = stmts;
    }

    override Variant accept(IExpressionVisitor visitor)
    {
        return visitor.visitFunctionLiteralNode(this);
    }

    override string toString() const
    {
        string output = "function(";
        for(size_t i = 0; i < argList.length; ++i)
        {
            output ~= argList[i];
            if(i < argList.length - 1)
                output ~= ", ";
        }
        output ~= "){\n";
        foreach(stmt ; statements)
        {
            output ~= "\t" ~ stmt.toString();
        }
        output ~= "\n}";
        return output;
    }

    string[] argList;
    StatementNode[] statements;
}

class ArrayLiteralNode : ExpressionNode 
{
    this(ExpressionNode[] values)
    {
        valueNodes = values;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitArrayLiteralNode(this);
	}

    override string toString() const
    {
        return format("%s", valueNodes);
    }

    ExpressionNode[] valueNodes;
}

class ObjectLiteralNode : ExpressionNode 
{
    this(string[] ks, ExpressionNode[] vs)
    {
        keys = ks;
        valueNodes = vs;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitObjectLiteralNode(this);
	}

    override string toString() const
    {
        // return "(object literal node)";
        if(keys.length != valueNodes.length)
            return "{invalid_object}";
        auto result = "{";
        for(size_t i = 0; i < keys.length; ++i)
            result ~= keys[i] ~ ":" ~ valueNodes[i].toString;
        result ~= "}";
        return result;
    }

    string[] keys;
    ExpressionNode[] valueNodes;
}

class ClassLiteralNode : ExpressionNode 
{
    this(ScriptFunction cfn, string[] mnames, ScriptFunction[] ms, string[] gnames, ScriptFunction[] gs, 
			string[] snames, ScriptFunction[] ss, string[] statNames, ScriptFunction[] statics, ExpressionNode baseClass)
    {
        constructorFn = cfn;
		methodNames = mnames;
		methods = ms;
		assert(methodNames.length == methods.length);
		getterNames = gnames;
		getters = gs;
		assert(getterNames.length == getters.length);
		setterNames = snames;
		setters = ss;
		assert(setterNames.length == setters.length);
		staticMethodNames = statNames;
		staticMethods = statics;
		assert(staticMethodNames.length == staticMethods.length);
        baseClassNode = baseClass;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitClassLiteralNode(this);
	}

    override string toString() const 
    {
        auto str = "class";
        if(baseClassNode !is null)
            str ~= " extends " ~ baseClassNode.toString();
        return str;
    }

    ScriptFunction constructorFn;
	string[] methodNames;
	ScriptFunction[] methods;
	string[] getterNames;
	ScriptFunction[] getters;
	string[] setterNames;
	ScriptFunction[] setters;
	string[] staticMethodNames;
	ScriptFunction[] staticMethods;
	ExpressionNode baseClassNode;
}

class BinaryOpNode : ExpressionNode
{
    this(Token op, ExpressionNode left, ExpressionNode right)
    {
        opToken = op;
        leftNode = left;
        rightNode = right;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitBinaryOpNode(this);
	}

    override string toString() const
    {
        return format("(%s %s %s)", leftNode, opToken.symbol, rightNode);
    }

    Token opToken;
    ExpressionNode leftNode;
    ExpressionNode rightNode;
}

class UnaryOpNode : ExpressionNode
{
    this(Token op, ExpressionNode operand)
    {
        opToken = op;
        operandNode = operand;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitUnaryOpNode(this);
	}

    override string toString() const
    {
        return format("(%s %s)", opToken.symbol, operandNode);
    }

    Token opToken;
    ExpressionNode operandNode;
}

class PostfixOpNode : ExpressionNode 
{
    this(Token op, ExpressionNode node)
    {
        opToken = op;
        operandNode = node;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitPostfixOpNode(this);
	}

    override string toString() const 
    {
        return operandNode.toString() ~ opToken.symbol;
    }

    Token opToken;
    ExpressionNode operandNode;
}

class TerniaryOpNode : ExpressionNode 
{
    this(ExpressionNode cond, ExpressionNode onTrue, ExpressionNode onFalse)
    {
        conditionNode = cond;
        onTrueNode = onTrue;
        onFalseNode = onFalse;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitTerniaryOpNode(this);
	}

    override string toString() const 
    {
        return conditionNode.toString() ~ "? " ~ onTrueNode.toString() ~ " : " ~ onFalseNode.toString();
    }

    ExpressionNode conditionNode;
    ExpressionNode onTrueNode;
    ExpressionNode onFalseNode;
}

class VarAccessNode : ExpressionNode
{
    this(Token token)
    {
        varToken = token;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitVarAccessNode(this);
	}

    override string toString() const
    {
        return varToken.text;
    }

    Token varToken;
}

class FunctionCallNode : ExpressionNode
{
    this(ExpressionNode fn, ExpressionNode[] args, bool retThis=false)
    {
        functionToCall = fn;
        expressionArgs = args;
        returnThis = retThis;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitFunctionCallNode(this);
	}

    override string toString() const
    {
        auto str = functionToCall.toString ~ "(";
        for(size_t i = 0; i < expressionArgs.length; ++i)
        {
            str ~= expressionArgs[i].toString;
            if(i < expressionArgs.length - 1) // @suppress(dscanner.suspicious.length_subtraction)
                str ~= ", ";
        }
        str ~= ")";
        return str;
    }

    ExpressionNode functionToCall;
    ExpressionNode[] expressionArgs;
    bool returnThis;
}

// when [] operator is used
class ArrayIndexNode : ExpressionNode 
{
    this(ExpressionNode obj, ExpressionNode index)
    {
        objectNode = obj;
        indexValueNode = index;
    }    

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitArrayIndexNode(this);
	}

    override string toString() const
    {
        return objectNode.toString() ~ "[" ~ indexValueNode.toString() ~ "]";
    }

    ExpressionNode objectNode;
    ExpressionNode indexValueNode;
}

class MemberAccessNode : ExpressionNode 
{
    this(ExpressionNode obj, ExpressionNode member)
    {
        objectNode = obj;
        memberNode = member;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitMemberAccessNode(this);
	}

    override string toString() const
    {
        return objectNode.toString() ~ "." ~ memberNode.toString();
    }

    ExpressionNode objectNode;
    ExpressionNode memberNode;
}

class NewExpressionNode : ExpressionNode 
{
    this(ExpressionNode fn)
    {
        functionCallExpression = fn;
    }

	override Variant accept(IExpressionVisitor visitor)
	{
		return visitor.visitNewExpressionNode(this);
	}

    override string toString() const
    {
        return "new " ~ functionCallExpression.toString();
    }

    ExpressionNode functionCallExpression;
}

/// root class of all statement nodes
abstract class StatementNode
{
    this(size_t lineNo)
    {
        line = lineNo;
    }

	abstract Variant accept(IStatementVisitor visitor);

    override string toString() const
    {
        assert(false, "This method is virtual and should never be called directly");
    }

    immutable size_t line;
}

class VarDeclarationStatementNode : StatementNode
{
    this(Token qual, ExpressionNode[] nodes)
    {
        super(qual.position.line);
        qualifier = qual;
        varAccessOrAssignmentNodes = nodes;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitVarDeclarationStatementNode(this);
	}

    override string toString() const
    {
        string str = qualifier.text ~ " ";
        for(size_t i = 0; i < varAccessOrAssignmentNodes.length; ++i)
        {
            str ~= varAccessOrAssignmentNodes[i].toString();
            if(i < varAccessOrAssignmentNodes.length - 1) // @suppress(dscanner.suspicious.length_subtraction)
                str ~= ", ";
        }
        return str;
    }

    Token qualifier; // must be var, let, or const
    ExpressionNode[] varAccessOrAssignmentNodes; // must be VarAccessNode or BinaryOpNode. should be validated by parser
}

class BlockStatementNode: StatementNode
{
    this(size_t lineNo, StatementNode[] statements)
    {
        super(lineNo);
        statementNodes = statements;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitBlockStatementNode(this);
	}

    override string toString() const
    {
        string str = "{\n";
        foreach(st ; statementNodes)
        {
            str ~= "  " ~ st.toString ~ "\n";
        }
        str ~= "}";
        return str;
    }

    StatementNode[] statementNodes;
}

class IfStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode condition, StatementNode onTrue, StatementNode onFalse=null)
    {
        super(lineNo);
        conditionNode = condition;
        onTrueStatement = onTrue;
        onFalseStatement = onFalse;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitIfStatementNode(this);
	}

    override string toString() const
    {
        auto str = "if(" ~ conditionNode.toString() ~ ") ";
        str ~= onTrueStatement.toString();
        if(onFalseStatement !is null)
            str ~= " else " ~ onFalseStatement.toString();
        return str;
    }

    ExpressionNode conditionNode;
    StatementNode onTrueStatement, onFalseStatement;
}

class SwitchStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode expr, SwitchBody sbody)
    {
        super(lineNo);
        expressionNode = expr;
        switchBody = sbody;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitSwitchStatementNode(this);
	}

    ExpressionNode expressionNode; // expression to test
    SwitchBody switchBody;
}

class SwitchBody
{
    this(StatementNode[] statements, size_t defaultID, size_t[ScriptAny] jumpTableID)
    {
        statementNodes = statements;
        defaultStatementID = defaultID;
        jumpTable = jumpTableID;
    }

    StatementNode[] statementNodes;
    size_t defaultStatementID; // index into statementNodes
    size_t[ScriptAny] jumpTable; // indexes into statementNodes
}

class WhileStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode condition, StatementNode bnode, string lbl = "")
    {
        super(lineNo);
        conditionNode = condition;
        bodyNode = bnode;
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitWhileStatementNode(this);
	}

    override string toString() const
    {
        auto str = "while(" ~ conditionNode.toString() ~ ") ";
        str ~= bodyNode.toString();
        return str;
    }

    ExpressionNode conditionNode;
    StatementNode bodyNode;
    string label;
}

class DoWhileStatementNode : StatementNode
{
    this(size_t lineNo, StatementNode bnode, ExpressionNode condition, string lbl="")
    {
        super(lineNo);
        bodyNode = bnode;
        conditionNode = condition;
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitDoWhileStatementNode(this);
	}

    override string toString() const
    {
        auto str = "do " ~ bodyNode.toString() ~ " while("
            ~ conditionNode.toString() ~ ")";
        return str;
    }

    StatementNode bodyNode;
    ExpressionNode conditionNode;
    string label;
}

class ForStatementNode : StatementNode
{
    this(size_t lineNo, VarDeclarationStatementNode decl, ExpressionNode condition, ExpressionNode increment, 
         StatementNode bnode, string lbl="")
    {
        super(lineNo);
        varDeclarationStatement = decl;
        conditionNode = condition;
        incrementNode = increment;
        bodyNode = bnode;
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitForStatementNode(this);
	}

    override string toString() const
    {
        auto decl = "";
        if(varDeclarationStatement !is null)
            decl = varDeclarationStatement.toString();
        auto str = "for(" ~ decl ~ ";" ~ conditionNode.toString() 
            ~ ";" ~ incrementNode.toString() ~ ") " ~ bodyNode.toString();
        return str;
    }

    VarDeclarationStatementNode varDeclarationStatement;
    ExpressionNode conditionNode;
    ExpressionNode incrementNode;
    StatementNode bodyNode;
    string label;
}

// for of can't do let {a,b} but it can do let a,b and be used the same as for in in JS
class ForOfStatementNode : StatementNode
{
    this(size_t lineNo, Token qual, VarAccessNode[] vans, ExpressionNode obj, StatementNode bnode, string lbl="")
    {
        super(lineNo);
        qualifierToken = qual;
        varAccessNodes = vans;
        objectToIterateNode = obj;
        bodyNode = bnode;
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitForOfStatementNode(this);
	}

    override string toString() const
    {
        auto str = "for(" ~ qualifierToken.text;
        for(size_t i = 0; i < varAccessNodes.length; ++i)
        {
            str ~= varAccessNodes[i].varToken.text;
            if(i < varAccessNodes.length - 1) // @suppress(dscanner.suspicious.length_subtraction)
                str ~= ", ";
        }
        str ~= " of " 
            ~ objectToIterateNode.toString() ~ ")" 
            ~ bodyNode.toString();
        return str;
    }

    Token qualifierToken;
    VarAccessNode[] varAccessNodes;
    ExpressionNode objectToIterateNode;
    StatementNode bodyNode;
    string label;
}

class BreakStatementNode : StatementNode
{
    this(size_t lineNo, string lbl="")
    {
        super(lineNo);
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitBreakStatementNode(this);
	}

    override string toString() const
    {
        return "break " ~ label ~ ";";
    }

    string label;
}

class ContinueStatementNode : StatementNode
{
    this(size_t lineNo, string lbl = "")
    {
        super(lineNo);
        label = lbl;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitContinueStatementNode(this);
	}

    override string toString() const
    {
        return "continue " ~ label ~ ";";
    }

    string label;
}

class ReturnStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode expr = null)
    {
        super(lineNo);
        expressionNode = expr;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitReturnStatementNode(this);
	}

    override string toString() const
    {
        auto str = "return";
        if(expressionNode !is null)
            str ~= " " ~ expressionNode.toString;
        return str ~ ";";
    }

    ExpressionNode expressionNode;
}

class FunctionDeclarationStatementNode : StatementNode
{
    this(size_t lineNo, string n, string[] args, StatementNode[] statements)
    {
        super(lineNo);
        name = n;
        argNames = args;
        statementNodes = statements;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitFunctionDeclarationStatementNode(this);
	}

    override string toString() const
    {
        auto str = "function " ~ name ~ "(";
        for(int i = 0; i < argNames.length; ++i)
        {
            str ~= argNames[i];
            if(i < argNames.length - 1) // @suppress(dscanner.suspicious.length_subtraction)
                str ~= ", ";
        }
        str ~= ") {";
        foreach(st ; statementNodes)
            str ~= "\t" ~ st.toString;
        str ~= "}";
        return str;
    }

    string name;
    string[] argNames;
    StatementNode[] statementNodes;
}

class ThrowStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode expr)
    {
        super(lineNo);
        expressionNode = expr;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitThrowStatementNode(this);
	}

    override string toString() const
    {
        return "throw " ~ expressionNode.toString() ~ ";";
    }

    ExpressionNode expressionNode;
}

class TryCatchBlockStatementNode : StatementNode
{
    this(size_t lineNo, StatementNode tryBlock, string name, StatementNode catchBlock)
    {
        super(lineNo);
        tryBlockNode = tryBlock;
        exceptionName = name;
        catchBlockNode = catchBlock;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitTryCatchBlockStatementNode(this);
	}

    override string toString() const
    {
        return "try " ~ tryBlockNode.toString ~ " catch(" ~ exceptionName ~ ")"
            ~ catchBlockNode.toString;
    }

    StatementNode tryBlockNode;
    string exceptionName;
    StatementNode catchBlockNode;
}

class DeleteStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode accessNode)
    {
        super(lineNo);
        memberAccessOrArrayIndexNode = accessNode;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitDeleteStatementNode(this);
	}

    override string toString() const
    {
        return "delete " ~ memberAccessOrArrayIndexNode.toString ~ ";";
    }

    ExpressionNode memberAccessOrArrayIndexNode;
}

class ClassDeclarationStatementNode : StatementNode
{
    this(size_t lineNo, string name, ScriptFunction con, string[] mnames, ScriptFunction[] ms, 
         string[] gnames, ScriptFunction[] getters, string[] snames, ScriptFunction[] setters,
		 string[] sfnNames, ScriptFunction[] staticMs, 
         ExpressionNode bc = null)
    {
        super(lineNo);
        className = name;
        constructor = con; // can't be null must at least be ScriptFunction.emptyFunction("NameOfClass")
        methodNames = mnames;
        methods = ms;
        assert(methodNames.length == methods.length);
        getMethodNames = gnames;
        getMethods = getters;
        assert(getMethodNames.length == getMethods.length);
        setMethodNames = snames;
        setMethods = setters;
        assert(setMethodNames.length == setMethods.length);
		staticMethodNames = sfnNames;
		staticMethods = staticMs;
		assert(staticMethodNames.length == staticMethods.length);
        baseClass = bc;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitClassDeclarationStatementNode(this);
	}

    string className;
    ScriptFunction constructor;
    string[] methodNames;
    ScriptFunction[] methods;
    string[] getMethodNames;
    ScriptFunction[] getMethods;
    string[] setMethodNames;
    ScriptFunction[] setMethods;
	string[] staticMethodNames;
	ScriptFunction[] staticMethods;
    ExpressionNode baseClass; // should be an expression that returns a constructor function
}

class SuperCallStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode ctc, ExpressionNode[] args)
    {
        super(lineNo);
        classConstructorToCall = ctc; // Cannot be null or something wrong with parser
        argExpressionNodes = args;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitSuperCallStatementNode(this);
	}

    ExpressionNode classConstructorToCall; // should always evaluate to a function
    ExpressionNode[] argExpressionNodes;
}

class ExpressionStatementNode : StatementNode
{
    this(size_t lineNo, ExpressionNode expression)
    {
        super(lineNo);
        expressionNode = expression;
    }

	override Variant accept(IStatementVisitor visitor)
	{
		return visitor.visitExpressionStatementNode(this);
	}

    override string toString() const
    {
        if(expressionNode is null)
            return ";";
        return expressionNode.toString() ~ ";";
    }

    ExpressionNode expressionNode;
}
