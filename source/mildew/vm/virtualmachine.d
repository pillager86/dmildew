module mildew.vm.virtualmachine;

import std.concurrency;
import std.conv: to;
import std.stdio;
import std.string;
import std.typecons;

import mildew.environment;
import mildew.exceptions;
import mildew.vm.chunk;
import mildew.vm.consttable;
import mildew.types;
import mildew.util.encode;
import mildew.util.stack;

/// 8-bit opcodes
enum OpCode : ubyte 
{
    NOP, // nop() -> ip += 1
    CONST, // const(uint) : load a const by index from the const table
    CONST_0, // const0() : load long(0) on to stack
    CONST_1, // const1() : push 1 to the stack
    CONST_N1, // constN1() : push -1 to the stack
    PUSH, // push(int) : push a stack value, can start at -1
    POP, // pop() : remove exactly one value from stack
    POPN, // pop(uint) : remove n values from stack
    SET, // set(uint) : set index of stack to value at top without popping stack
    STACK, // stack(uint) : add n number of undefines to stack
    STACK_1, // stack1() : add one undefined to stack
    ARRAY, // array(uint) : pops n items to create array and pushes to top
    OBJECT, // array(uint) : create an object from key-value pairs starting with stack[-n] so n must be even
    ITER, // pushes a function that returns {value:..., done:bool} performed on pop()
    NEW, // similar to call(uint) except only func, arg1, arg2, etc.
    THIS, // pushes local "this" or undefined if not found
    OPENSCOPE, // openscope() : open an environment scope
    CLOSESCOPE, // closescope() : close an environment scope
    DECLVAR, // declvar(uint) : declare pop() to a global described by a const string
    DECLLET, // decllet(uint) : declare pop() to a local described by a const string
    DECLCONST, // declconst(uint) : declare pop() as stack[-2] to a local const described by a const
    GETVAR, // getvar(uint) : push variable described by const table string on to stack
    SETVAR, // setvar(uint) : store top() in variable described by const table index string leave value on top
    OBJGET, // objget() : retrieves stack[-2][stack[-1]], popping 2 and pushing 1
    OBJSET, // objset() : sets stack[-3][stack[-2]] to stack[-1], pops 3 and pushes the value that was set
    CALL, // call(uint) : stack should be this, func, arg1, arg2, arg3 and arg would be 3
    JMPFALSE, // jmpfalse(int) : relative jump
    JMP,  // jmp(int) -> : relative jump
    SWITCH, // switch(uint) -> arg=abs jmp, stack[-2] jmp table stack[-1] value to test
    GOTO, // goto(uint, ubyte) : absolute ip. second param is number of scopes to subtract
    THROW, // throw() : throws pop() as a script runtime exception
    RETHROW, // rethrow() : rethrow the exception flag, should only be generated with try-finally
    TRY, // try(uint) : parameter is ip to goto for catch (or sometimes finally if finally only)
    ENDTRY, // pop unconsumed try-entry from try-entry list
    LOADEXC, // loads the current exception on to stack, either message or thrown value
    
    // special ops
    CONCAT, // concat(uint) : concat N elements on stack and push resulting string

    // binary and unary and terniary ops
    BITNOT, // bitwise not
    NOT, // not top()
    NEGATE, // negate top()
    TYPEOF, // typeof operator
    POW, // exponent operation
    MUL, // multiplication
    DIV, // division
    MOD, // modulo
    ADD, // add() : adds stack[-2,-1], pops 2, push 1
    SUB, // minus
    BITLSH, // bit shift left top
    BITRSH, // bit shift right top
    BITURSH, // bit shift right unsigned
    LT, // less than
    LE, // less than or equal
    GT, // greater than
    GE, // greater than or equal
    EQUALS, // equals
    NEQUALS, // !equals
    BITAND, // bitwise and
    BITOR, // bitwise or
    BITXOR, // bitwise xor
    AND, // and
    OR, // or
    TERN, // : ? looks at stack[-3..-1]

    RETURN, // return from a function, should leave exactly one value on stack
    HALT, // completely stop the vm
}

alias OpCodeFunction = int function(VirtualMachine, Chunk chunk);

/// helper function. TODO: rework as flag system that implements try-catch-finally mechanics
private int throwRuntimeError(in string message, VirtualMachine vm, Chunk chunk, 
                            ScriptAny thrownValue = ScriptAny.UNDEFINED, 
                            ScriptRuntimeException rethrow = null)
{
    vm._exc = new ScriptRuntimeException(message);
    if(thrownValue != ScriptAny.UNDEFINED)
        vm._exc.thrownValue = thrownValue;
    if(rethrow)
        vm._exc = rethrow;
    // unwind stack starting with current
    if(chunk.bytecode in chunk.debugMap)
    {
        immutable lineNum = chunk.debugMap[chunk.bytecode].getLineNumber(vm._ip);
        vm._exc.scriptTraceback ~= tuple(lineNum, chunk.debugMap[chunk.bytecode].getSourceLine(lineNum));
    }
    // consume latest try-data entry if available
    if(vm._tryData.length > 0)
    {
        immutable tryData = vm._tryData[$-1];
        vm._tryData = vm._tryData[0..$-1];
        immutable depthToReduce = vm._environment.depth - tryData.depth;
        for(int i = 0; i < depthToReduce; ++i)
            vm._environment = vm._environment.parent;
        vm._stack.size = tryData.stackSize;
        vm._ip = tryData.catchGoto;
        return 1;
    }
    while(vm._callStack.size > 0)
    {
        auto csData = vm._callStack.pop(); // @suppress(dscanner.suspicious.unmodified)
        vm._ip = csData.ip;
        chunk.bytecode = csData.bc;
        vm._tryData = csData.tryData;
        vm._environment = csData.env;
        if(chunk.bytecode in chunk.debugMap)
        {
            immutable lineNum = chunk.debugMap[chunk.bytecode].getLineNumber(vm._ip);
            vm._exc.scriptTraceback ~= tuple(lineNum, chunk.debugMap[chunk.bytecode].getSourceLine(lineNum));
        }
        // look for a try-data entry from the popped call stack
        if(vm._tryData.length > 0)
        {
            immutable tryData = vm._tryData[$-1];
            vm._tryData = vm._tryData[0..$-1];
            immutable depthToReduce = vm._environment.depth - tryData.depth;
            for(int i = 0; i < depthToReduce; ++i)
                vm._environment = vm._environment.parent;
            vm._stack.size = tryData.stackSize;
            vm._ip = tryData.catchGoto;
            return 1;
        }
    }
    // there is no available script exception handler found so throw the exception
    throw vm._exc;
}

private string opCodeToString(const OpCode op)
{
    return op.to!string().toLower();
}

pragma(inline, true)
private int opNop(VirtualMachine vm, Chunk chunk)
{
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opConst(VirtualMachine vm, Chunk chunk)
{
    immutable constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto value = chunk.constTable.get(constID);
    if(value.type == ScriptAny.Type.FUNCTION)
        value = value.toValue!ScriptFunction().copyCompiled(vm._environment);
    vm._stack.push(value);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opConst0(VirtualMachine vm, Chunk chunk)
{
    vm._stack.push(ScriptAny(0));
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opConst1(VirtualMachine vm, Chunk chunk)
{
    vm._stack.push(ScriptAny(1));
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opPush(VirtualMachine vm, Chunk chunk)
{
    immutable index = decode!int(chunk.bytecode.ptr + vm._ip + 1);
    if(index < 0)
        vm._stack.push(vm._stack.array[$ + index]);
    else
        vm._stack.push(vm._stack.array[index]);
    vm._ip += 1 + int.sizeof;
    return 0;
}

pragma(inline, true)
private int opPop(VirtualMachine vm, Chunk chunk)
{
    vm._stack.pop();
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opPopN(VirtualMachine vm, Chunk chunk)
{
    immutable amount = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    vm._stack.pop(amount);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opSet(VirtualMachine vm, Chunk chunk)
{
    immutable index = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    vm._stack.array[index] = vm._stack.array[$-1];
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opStack(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    ScriptAny[] undefineds = new ScriptAny[n];
    vm._stack.push(undefineds);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opStack1(VirtualMachine vm, Chunk chunk)
{
    vm._stack.push(ScriptAny.UNDEFINED);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opArray(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto arr = vm._stack.pop(n);
    vm._stack.push(ScriptAny(arr));
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opObject(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1) * 2;
    auto pairList = vm._stack.pop(n);
    auto obj = new ScriptObject("object", null, null);
    for(uint i = 0; i < n; i += 2)
        obj[pairList[i].toString()] = pairList[i+1];
    vm._stack.push(ScriptAny(obj));
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opIter(VirtualMachine vm, Chunk chunk)
{
    auto objToIterate = vm._stack.pop();
    // can be a string, array, or object
    // FUTURE: a Generator returned by a Generator function
    if(!(objToIterate.isObject))
        return throwRuntimeError("Cannot iterate over non-object " ~ objToIterate.toString, vm, chunk);
    if(objToIterate.type == ScriptAny.Type.STRING)
    {
        immutable elements = objToIterate.toValue!string;
        auto generator = new Generator!(Tuple!(size_t,dstring))({
            size_t indexCounter = 0;
            foreach(dchar ele ; elements)
            {
                ++indexCounter;
                yield(tuple(indexCounter-1,ele.to!dstring));
            }
        });
        vm._stack.push(ScriptAny(new ScriptFunction("next", 
            delegate ScriptAny(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError){
                auto retVal = new ScriptObject("iteration", null, null);
                if(generator.empty)
                {
                    retVal.assignField("done", ScriptAny(true));
                }
                else 
                {
                    auto result = generator.front();
                    retVal.assignField("key", ScriptAny(result[0]));
                    retVal.assignField("value", ScriptAny(result[1]));
                    generator.popFront();
                }
                return ScriptAny(retVal);
            }, 
            false)));
    }
    else if(objToIterate.type == ScriptAny.Type.ARRAY)
    {
        auto elements = objToIterate.toValue!(ScriptAny[]); // @suppress(dscanner.suspicious.unmodified)
        auto generator = new Generator!(Tuple!(size_t, ScriptAny))({
            size_t indexCounter = 0;
            foreach(item ; elements)
            {
                ++indexCounter;
                yield(tuple(indexCounter-1, item));
            }
        });
        vm._stack.push(ScriptAny(new ScriptFunction("next",
            delegate ScriptAny(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError) {
                auto retVal = new ScriptObject("iteration", null, null);
                if(generator.empty)
                {
                    retVal.assignField("done", ScriptAny(true));
                }
                else 
                {
                    auto result = generator.front();
                    retVal.assignField("key", ScriptAny(result[0]));
                    retVal.assignField("value", ScriptAny(result[1]));
                    generator.popFront();
                }
                return ScriptAny(retVal);
            })));
    }
    else if(objToIterate.isObject)
    {
        auto obj = objToIterate.toValue!ScriptObject;
        auto generator = new Generator!(Tuple!(string, ScriptAny))({
            foreach(k, v ; obj.dictionary)
                yield(tuple(k,v));
        });
        vm._stack.push(ScriptAny(new ScriptFunction("next", 
            delegate ScriptAny(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError){
                auto retVal = new ScriptObject("iteration", null, null);
                if(generator.empty)
                {
                    retVal.assignField("done", ScriptAny(true));
                }
                else
                {
                    auto result = generator.front();
                    retVal.assignField("key", ScriptAny(result[0]));
                    retVal.assignField("value", result[1]);
                    generator.popFront();
                }
                return ScriptAny(retVal);
        })));
    }
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opNew(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1) + 1;
    auto callInfo = vm._stack.pop(n);
    auto funcAny = callInfo[0];
    auto args = callInfo[1..$];
    
    NativeFunctionError nfe = NativeFunctionError.NO_ERROR;
    if(funcAny.type != ScriptAny.Type.FUNCTION)
        return throwRuntimeError("Unable to instantiate new object from non-function " ~ funcAny.toString(), vm, chunk);
    auto func = funcAny.toValue!ScriptFunction; // @suppress(dscanner.suspicious.unmodified)

    ScriptAny thisObj = new ScriptObject(func.functionName, func["prototype"].toValue!ScriptObject, null);

    if(func.type == ScriptFunction.Type.SCRIPT_FUNCTION)
    {
        if(func.compiled.length == 0)
            throw new VMException("Empty script function cannot be called", vm._ip, OpCode.CALL);
        vm._callStack.push(VirtualMachine.CallData(VirtualMachine.FuncCallType.NEW, chunk.bytecode, 
                vm._ip, vm._environment, vm._tryData));
        vm._environment = new Environment(func.closure, func.functionName);
        vm._ip = 0;
        chunk.bytecode = func.compiled;
        vm._tryData = [];
        // set this
        vm._environment.forceSetVarOrConst("this", thisObj, true);
        // set args
        for(size_t i = 0; i < func.argNames.length; ++i)
        {
            if(i >= args.length)
                vm._environment.forceSetVarOrConst(func.argNames[i], ScriptAny.UNDEFINED, false);
            else
                vm._environment.forceSetVarOrConst(func.argNames[i], args[i], false);
        }
        return 0;
    }
    else if(func.type == ScriptFunction.Type.NATIVE_FUNCTION)
    {
        auto nativeFunc = func.nativeFunction;
        nativeFunc(vm._environment, &thisObj, args, nfe);
        vm._stack.push(thisObj);
    }
    else if(func.type == ScriptFunction.Type.NATIVE_DELEGATE)
    {
        auto nativeDelegate = func.nativeDelegate;
        nativeDelegate(vm._environment, &thisObj, args, nfe);
        vm._stack.push(thisObj);
    }
    final switch(nfe)
    {
    case NativeFunctionError.NO_ERROR:
        break;
    case NativeFunctionError.RETURN_VALUE_IS_EXCEPTION:
        return throwRuntimeError(vm._stack.pop().toString(), vm, chunk);
    case NativeFunctionError.WRONG_NUMBER_OF_ARGS:
        return throwRuntimeError("Wrong number of arguments to native function", vm, chunk);
    case NativeFunctionError.WRONG_TYPE_OF_ARG:
        return throwRuntimeError("Wrong type of argument to native function", vm, chunk);
    }
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opThis(VirtualMachine vm, Chunk chunk)
{
    bool _; // @suppress(dscanner.suspicious.unmodified)
    auto thisPtr = vm._environment.lookupVariableOrConst("this", _);
    if(thisPtr == null)
        vm._stack.push(ScriptAny.UNDEFINED);
    else
        vm._stack.push(*thisPtr);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opOpenScope(VirtualMachine vm, Chunk chunk)
{
    vm._environment = new Environment(vm._environment);
    // debug writefln("VM{ environment depth=%s", vm._environment.depth);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opCloseScope(VirtualMachine vm, Chunk chunk)
{
    vm._environment = vm._environment.parent;
    // debug writefln("VM} environment depth=%s", vm._environment.depth);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opDeclVar(VirtualMachine vm, Chunk chunk)
{
    auto constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto varName = chunk.constTable.get(constID).toString();
    auto value = vm._stack.pop();
    immutable ok = vm._globals.declareVariableOrConst(varName, value, false);
    if(!ok)
        return throwRuntimeError("Cannot redeclare global " ~ varName, vm, chunk);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opDeclLet(VirtualMachine vm, Chunk chunk)
{
    auto constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto varName = chunk.constTable.get(constID).toString();
    auto value = vm._stack.pop();
    immutable ok = vm._environment.declareVariableOrConst(varName, value, false);
    if(!ok)
        return throwRuntimeError("Cannot redeclare local " ~ varName, vm, chunk);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opDeclConst(VirtualMachine vm, Chunk chunk)
{
    auto constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto varName = chunk.constTable.get(constID).toString();
    auto value = vm._stack.pop();
    immutable ok = vm._environment.declareVariableOrConst(varName, value, true);
    if(!ok)
        return throwRuntimeError("Cannot redeclare const " ~ varName, vm, chunk);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opGetVar(VirtualMachine vm, Chunk chunk)
{
    auto constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto varName = chunk.constTable.get(constID).toString();
    bool isConst; // @suppress(dscanner.suspicious.unmodified)
    auto valuePtr = vm._environment.lookupVariableOrConst(varName, isConst);
    if(valuePtr == null)
        return throwRuntimeError("Variable lookup failed: " ~ varName, vm, chunk);
    vm._stack.push(*valuePtr);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opSetVar(VirtualMachine vm, Chunk chunk)
{
    auto constID = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto varName = chunk.constTable.get(constID).toString();
    bool isConst; // @suppress(dscanner.suspicious.unmodified)
    auto varPtr = vm._environment.lookupVariableOrConst(varName, isConst);
    if(varPtr == null)
    {
        return throwRuntimeError("Cannot assign to undefined variable: " ~ varName, vm, chunk);
    }
    auto value = vm._stack.peek(); // @suppress(dscanner.suspicious.unmodified)
    if(value == ScriptAny.UNDEFINED)
        vm._environment.unsetVariable(varName);
    else
        *varPtr = value;
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opObjGet(VirtualMachine vm, Chunk chunk)
{
    auto objToAccess = vm._stack.array[$-2];
    auto field = vm._stack.array[$-1]; // @suppress(dscanner.suspicious.unmodified)
    vm._stack.pop(2);
    // TODO handle getters
    // if field is integer it is array access
    if(field.type == ScriptAny.Type.INTEGER)
    {
        auto index = field.toValue!long;
        if(objToAccess.type == ScriptAny.Type.ARRAY)
        {
            auto arr = objToAccess.toValue!(ScriptAny[]);
            if(index < 0)
                index = arr.length + index;
            if(index < 0 || index >= arr.length)
                return throwRuntimeError("Out of bounds array access", vm, chunk);
            vm._stack.push(arr[index]);
        }
        else if(objToAccess.type == ScriptAny.Type.STRING)
        {
            auto wstr = objToAccess.toValue!(ScriptString)().getWString();
            if(index < 0)
                index = wstr.length + index;
            if(index < 0 || index >= wstr.length)
                return throwRuntimeError("Out of bounds string access", vm, chunk);
            vm._stack.push(ScriptAny([wstr[index]]));
        }
        else
        {
            return throwRuntimeError("Value " ~ objToAccess.toString() ~ " is not an array or string", vm, chunk);
        }
    }
    else // else object field access
    {
        auto index = field.toString();
        if(!objToAccess.isObject)
            return throwRuntimeError("Unable to access members of non-object " ~ objToAccess.toString(), vm, chunk);
        // TODO check getters and run them if found
        // for now just access fields
        vm._stack.push(objToAccess[index]);
    }
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opObjSet(VirtualMachine vm, Chunk chunk)
{
    auto objToAccess = vm._stack.array[$-3];
    auto fieldToAssign = vm._stack.array[$-2]; // @suppress(dscanner.suspicious.unmodified)
    auto value = vm._stack.array[$-1];
    vm._stack.pop(3);
    if(fieldToAssign.type == ScriptAny.Type.INTEGER)
    {
        auto index = fieldToAssign.toValue!long;
        if(objToAccess.type == ScriptAny.Type.ARRAY)
        {
            auto arr = objToAccess.toValue!(ScriptAny[]);
            if(index < 0)
                index = arr.length + index;
            if(index < 0 || index >= arr.length)
                return throwRuntimeError("Out of bounds array assignment", vm, chunk);
            arr[index] = value;
            vm._stack.push(value);
        }
        else
        {
            return throwRuntimeError("Value " ~ objToAccess.toString() ~ " is not an array", vm, chunk);
        }
    }
    else
    {
        auto index = fieldToAssign.toValue!string;
        if(!objToAccess.isObject)
            return throwRuntimeError("Unable to assign member of non-object " ~ objToAccess.toString(), vm, chunk);
        // TODO check setters, and in cases where there is a setter but no getter, undefined will be pushed
        objToAccess[index] = value;
        vm._stack.push(value);
    }
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opCall(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1) + 2;
    auto callInfo = vm._stack.pop(n);
    auto thisObj = callInfo[0]; // @suppress(dscanner.suspicious.unmodified)
    auto funcAny = callInfo[1];
    auto args = callInfo[2..$];
    NativeFunctionError nfe = NativeFunctionError.NO_ERROR;
    if(funcAny.type != ScriptAny.Type.FUNCTION)
        return throwRuntimeError("Unable to call non-function " ~ funcAny.toString(), vm, chunk);
    auto func = funcAny.toValue!ScriptFunction; // @suppress(dscanner.suspicious.unmodified)
    if(func.type == ScriptFunction.Type.SCRIPT_FUNCTION)
    {
        if(func.compiled.length == 0)
            throw new VMException("Empty script function cannot be called", vm._ip, OpCode.CALL);
        vm._callStack.push(VirtualMachine.CallData(VirtualMachine.FuncCallType.NORMAL, chunk.bytecode, 
                vm._ip, vm._environment, vm._tryData));
        vm._environment = new Environment(func.closure, func.functionName);
        vm._ip = 0;
        chunk.bytecode = func.compiled;
        vm._tryData = [];
        // set this
        vm._environment.forceSetVarOrConst("this", thisObj, true);
        // set args
        for(size_t i = 0; i < func.argNames.length; ++i)
        {
            if(i >= args.length)
                vm._environment.forceSetVarOrConst(func.argNames[i], ScriptAny.UNDEFINED, false);
            else
                vm._environment.forceSetVarOrConst(func.argNames[i], args[i], false);
        }
        return 0;
    }
    else if(func.type == ScriptFunction.Type.NATIVE_FUNCTION)
    {
        auto nativeFunc = func.nativeFunction;
        vm._stack.push(nativeFunc(vm._environment, &thisObj, args, nfe));
    }
    else if(func.type == ScriptFunction.Type.NATIVE_DELEGATE)
    {
        auto nativeDelegate = func.nativeDelegate;
        vm._stack.push(nativeDelegate(vm._environment, &thisObj, args, nfe));
    }
    final switch(nfe)
    {
    case NativeFunctionError.NO_ERROR:
        break;
    case NativeFunctionError.RETURN_VALUE_IS_EXCEPTION:
        return throwRuntimeError(vm._stack.peek().toString(), vm, chunk);
    case NativeFunctionError.WRONG_NUMBER_OF_ARGS:
        return throwRuntimeError("Wrong number of arguments to native function", vm, chunk);
    case NativeFunctionError.WRONG_TYPE_OF_ARG:
        return throwRuntimeError("Wrong type of argument to native function", vm, chunk);
    }
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opJmpFalse(VirtualMachine vm, Chunk chunk)
{
    immutable jmpAmount = decode!int(chunk.bytecode.ptr + vm._ip + 1);
    immutable shouldJump = vm._stack.pop();
    if(!shouldJump)
        vm._ip += jmpAmount;
    else
        vm._ip += 1 + int.sizeof;
    return 0;
}

pragma(inline, true)
private int opJmp(VirtualMachine vm, Chunk chunk)
{
    immutable jmpAmount = decode!int(chunk.bytecode.ptr + vm._ip + 1);
    vm._ip += jmpAmount;
    return 0;
}

pragma(inline, true)
private int opSwitch(VirtualMachine vm, Chunk chunk)
{
    immutable relAbsJmp = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    auto valueToTest = vm._stack.pop();
    auto jumpTableArray = vm._stack.pop();
    // build the jump table out of the entries
    if(jumpTableArray.type != ScriptAny.Type.ARRAY)
        throw new VMException("Invalid jump table", vm._ip, OpCode.SWITCH);
    int[ScriptAny] jmpTable;
    foreach(entry ; jumpTableArray.toValue!(ScriptAny[]))
    {
        if(entry.type != ScriptAny.Type.ARRAY)
            throw new VMException("Invalid jump table entry", vm._ip, OpCode.SWITCH);
        auto entryArray = entry.toValue!(ScriptAny[]);
        if(entryArray.length < 2)
            throw new VMException("Invalid jump table entry size", vm._ip, OpCode.SWITCH);
        jmpTable[entryArray[0]] = entryArray[1].toValue!int;
    }
    if(valueToTest in jmpTable)
        vm._ip = jmpTable[valueToTest];
    else
        vm._ip = relAbsJmp;
    return 0;
}

pragma(inline, true)
private int opGoto(VirtualMachine vm, Chunk chunk)
{
    immutable address = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    immutable depth = decode!ubyte(chunk.bytecode.ptr + vm._ip + 1 + uint.sizeof);
    for(ubyte i = 0; i < depth; ++i)
    {
        vm._environment = vm._environment.parent;
    }
    vm._ip = address;
    return 0;
}

pragma(inline, true)
private int opThrow(VirtualMachine vm, Chunk chunk)
{
    auto valToThrow = vm._stack.pop();
    return throwRuntimeError("Uncaught script exception", vm, chunk, valToThrow);
}

pragma(inline, true)
private int opRethrow(VirtualMachine vm, Chunk chunk)
{
    if(vm._exc)
        return throwRuntimeError(vm._exc.msg, vm, chunk, vm._exc.thrownValue, vm._exc);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opTry(VirtualMachine vm, Chunk chunk)
{
    immutable catchGoto = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    immutable depth = cast(int)vm._environment.depth();
    vm._tryData ~= VirtualMachine.TryData(depth, vm._stack.size, catchGoto);
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opEndTry(VirtualMachine vm, Chunk chunk)
{
    vm._tryData = vm._tryData[0..$-1];
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opLoadExc(VirtualMachine vm, Chunk chunk)
{
    if(vm._exc is null)
        throw new VMException("An exception was never thrown", vm._ip, OpCode.LOADEXC);
    if(vm._exc.thrownValue != ScriptAny.UNDEFINED)
        vm._stack.push(vm._exc.thrownValue);
    else
        vm._stack.push(ScriptAny(vm._exc.msg));
    vm._exc = null; // once loaded by a catch block it should be cleared
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opConcat(VirtualMachine vm, Chunk chunk)
{
    immutable n = decode!uint(chunk.bytecode.ptr + vm._ip + 1);
    string result = "";
    auto values = vm._stack.pop(n);
    foreach(value ; values)
        result ~= value.toString();
    vm._stack.push(ScriptAny(result));
    vm._ip += 1 + uint.sizeof;
    return 0;
}

pragma(inline, true)
private int opBitNot(VirtualMachine vm, Chunk chunk)
{
    vm._stack.array[$-1] = ~vm._stack.array[$-1];
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opNot(VirtualMachine vm, Chunk chunk)
{
    vm._stack.array[$-1] = ScriptAny(!vm._stack.array[$-1]);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opNegate(VirtualMachine vm, Chunk chunk)
{
    vm._stack.array[$-1] = -vm._stack.array[$-1];
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opTypeof(VirtualMachine vm, Chunk chunk)
{
    vm._stack.array[$-1] = ScriptAny(vm._stack.array[$-1].typeToString());
    ++vm._ip;
    return 0;
}

private string DEFINE_BIN_OP(string name, string op)()
{
    import std.format: format;
    return format(q{
pragma(inline, true)
private int %1$s(VirtualMachine vm, Chunk chunk)
{
    auto operands = vm._stack.pop(2);
    vm._stack.push(operands[0] %2$s operands[1]);
    ++vm._ip;
    return 0;
}
    }, name, op);
}

mixin(DEFINE_BIN_OP!("opPow", "^^"));
mixin(DEFINE_BIN_OP!("opMul", "*"));
mixin(DEFINE_BIN_OP!("opDiv", "/"));
mixin(DEFINE_BIN_OP!("opMod", "%"));
mixin(DEFINE_BIN_OP!("opAdd", "+"));
mixin(DEFINE_BIN_OP!("opSub", "-"));
mixin(DEFINE_BIN_OP!("opBitRSh", ">>"));
mixin(DEFINE_BIN_OP!("opBitURSh", ">>>"));
mixin(DEFINE_BIN_OP!("opBitLSh", "<<"));

private string DEFINE_BIN_BOOL_OP(string name, string op)()
{
    import std.format: format;
    return format(q{
pragma(inline, true)
private int %1$s(VirtualMachine vm, Chunk chunk)
{
    auto operands = vm._stack.pop(2);
    vm._stack.push(ScriptAny(operands[0] %2$s operands[1]));
    ++vm._ip;
    return 0;
}
    }, name, op);
}

mixin(DEFINE_BIN_BOOL_OP!("opLT", "<"));
mixin(DEFINE_BIN_BOOL_OP!("opLE", "<="));
mixin(DEFINE_BIN_BOOL_OP!("opGT", ">"));
mixin(DEFINE_BIN_BOOL_OP!("opGE", "<"));
mixin(DEFINE_BIN_BOOL_OP!("opEQ", "=="));
mixin(DEFINE_BIN_BOOL_OP!("opNEQ", "!="));

mixin(DEFINE_BIN_OP!("opBitAnd", "&"));
mixin(DEFINE_BIN_OP!("opBitOr", "|"));
mixin(DEFINE_BIN_OP!("opBitXor", "^"));

mixin(DEFINE_BIN_BOOL_OP!("opAnd", "&&"));

pragma(inline, true)
private int opOr(VirtualMachine vm, Chunk chunk)
{
    auto operands = vm._stack.pop(2);
    vm._stack.push(operands[0].orOp(operands[1]));
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opTern(VirtualMachine vm, Chunk chunk)
{
    auto operands = vm._stack.pop(3);
    if(operands[0])
        vm._stack.push(operands[1]);
    else
        vm._stack.push(operands[2]);
    ++vm._ip;
    return 0;
}

pragma(inline, true)
private int opReturn(VirtualMachine vm, Chunk chunk)
{
    if(vm._stack.size < 1)
        throw new VMException("Return value missing from return", vm._ip, OpCode.RETURN);

    if(vm._callStack.size > 0)
    {
        auto fcdata = vm._callStack.pop(); // @suppress(dscanner.suspicious.unmodified)
        chunk.bytecode = fcdata.bc;
        if(fcdata.fct == VirtualMachine.FuncCallType.NEW)
        {
            // pop whatever was returned and push the "this"
            vm._stack.pop();
            bool _;
            vm._stack.push(*vm._environment.lookupVariableOrConst("this", _));
        }
        vm._ip = fcdata.ip;
        vm._environment = fcdata.env;
        vm._tryData = fcdata.tryData;
    }
    else
    {
        vm._ip = chunk.bytecode.length;
    }
    vm._ip += 1 + uint.sizeof; // the size of call()    
    return 0;
}

pragma(inline, true)
private int opHalt(VirtualMachine vm, Chunk chunk)
{
    vm._stopped = true;
    ++vm._ip;
    return 0;
}

/// implements virtual machine
class VirtualMachine
{
    /// ctor
    this(Environment globalEnv)
    {
        _environment = globalEnv;
        _globals = globalEnv;
        _ops[] = &opNop;
        _ops[OpCode.CONST] = &opConst;
        _ops[OpCode.CONST_0] = &opConst0;
        _ops[OpCode.CONST_1] = &opConst1;
        _ops[OpCode.PUSH] = &opPush;
        _ops[OpCode.POP] = &opPop;
        _ops[OpCode.POPN] = &opPopN;
        _ops[OpCode.SET] = &opSet;
        _ops[OpCode.STACK] = &opStack;
        _ops[OpCode.STACK_1] = &opStack1;
        _ops[OpCode.ARRAY] = &opArray;
        _ops[OpCode.OBJECT] = &opObject;
        _ops[OpCode.ITER] = &opIter;
        _ops[OpCode.NEW] = &opNew;
        _ops[OpCode.THIS] = &opThis;
        _ops[OpCode.OPENSCOPE] = &opOpenScope;
        _ops[OpCode.CLOSESCOPE] = &opCloseScope;
        _ops[OpCode.DECLVAR] = &opDeclVar;
        _ops[OpCode.DECLLET] = &opDeclLet;
        _ops[OpCode.DECLCONST] = &opDeclConst;
        _ops[OpCode.GETVAR] = &opGetVar;
        _ops[OpCode.SETVAR] = &opSetVar;
        _ops[OpCode.OBJGET] = &opObjGet;
        _ops[OpCode.OBJSET] = &opObjSet;
        _ops[OpCode.CALL] = &opCall;
        _ops[OpCode.JMPFALSE] = &opJmpFalse;
        _ops[OpCode.JMP] = &opJmp;
        _ops[OpCode.SWITCH] = &opSwitch;
        _ops[OpCode.GOTO] = &opGoto;
        _ops[OpCode.THROW] = &opThrow;
        _ops[OpCode.RETHROW] = &opRethrow;
        _ops[OpCode.TRY] = &opTry;
        _ops[OpCode.ENDTRY] = &opEndTry;
        _ops[OpCode.LOADEXC] = &opLoadExc;
        _ops[OpCode.CONCAT] = &opConcat;
        _ops[OpCode.BITNOT] = &opBitNot;
        _ops[OpCode.NOT] = &opNot;
        _ops[OpCode.NEGATE] = &opNegate;
        _ops[OpCode.TYPEOF] = &opTypeof;
        _ops[OpCode.POW] = &opPow;
        _ops[OpCode.MUL] = &opMul;
        _ops[OpCode.DIV] = &opDiv;
        _ops[OpCode.MOD] = &opMod;
        _ops[OpCode.ADD] = &opAdd;
        _ops[OpCode.SUB] = &opSub;
        _ops[OpCode.BITRSH] = &opBitRSh;
        _ops[OpCode.BITURSH] = &opBitURSh;
        _ops[OpCode.BITLSH] = &opBitLSh;
        _ops[OpCode.LT] = &opLT;
        _ops[OpCode.LE] = &opLE;
        _ops[OpCode.GT] = &opGT;
        _ops[OpCode.GE] = &opGE;
        _ops[OpCode.EQUALS] = &opEQ;
        _ops[OpCode.NEQUALS] = &opNEQ;
        _ops[OpCode.BITAND] = &opBitAnd;
        _ops[OpCode.BITOR] = &opBitOr;
        _ops[OpCode.BITXOR] = &opBitXor;
        _ops[OpCode.AND] = &opAnd;
        _ops[OpCode.OR] = &opOr;
        _ops[OpCode.TERN] = &opTern;
        _ops[OpCode.RETURN] = &opReturn;
        _ops[OpCode.HALT] = &opHalt;
        _stack.reserve(256);
    }

    /// print a chunk instruction by instruction, using the const table to indicate values
    void printChunk(Chunk chunk, bool printConstTable=false)
    {
        if(printConstTable)
        {
            writeln("===== CONST TABLE =====");
            foreach(index, value ; chunk.constTable)
            {
                writef("#%s: ", index);
                if(value.type == ScriptAny.Type.FUNCTION)
                {
                    auto fn = value.toValue!ScriptFunction;
                    writeln("<function> " ~ fn.functionName);
                    auto funcChunk = new Chunk();
                    funcChunk.constTable = chunk.constTable;
                    funcChunk.bytecode = fn.compiled;
                    printChunk(funcChunk, false);
                }
                else
                {
                    writeln("<" ~ value.typeToString() ~ "> " ~ value.toString());
                }
            }
        }
        if(printConstTable)
            writeln("===== DISASSEMBLY =====");
        size_t ip = 0;
        while(ip < chunk.bytecode.length)
        {
            auto op = cast(OpCode)chunk.bytecode[ip];
            printInstruction(ip, chunk);
            switch(op)
            {
            case OpCode.NOP:
                ++ip;
                break;
            case OpCode.CONST:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.CONST_0:
            case OpCode.CONST_1:
                ++ip;
                break;
            case OpCode.PUSH:
                ip += 1 + int.sizeof;
                break;
            case OpCode.POP:
                ++ip;
                break;
            case OpCode.POPN:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.SET: 
                ip += 1 + uint.sizeof;
                break;
            case OpCode.STACK:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.STACK_1:
                ++ip;
                break;
            case OpCode.ARRAY:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.OBJECT:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.ITER:
                ++ip;
                break;
            case OpCode.NEW:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.THIS:
                ++ip;
                break;
            case OpCode.OPENSCOPE:
                ++ip;
                break;
            case OpCode.CLOSESCOPE:
                ++ip;
                break;
            case OpCode.DECLVAR:
            case OpCode.DECLLET:
            case OpCode.DECLCONST:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.GETVAR:
            case OpCode.SETVAR:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.OBJGET:
            case OpCode.OBJSET:
                ++ip;
                break;
            case OpCode.CALL:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.JMPFALSE:
            case OpCode.JMP:
                ip += 1 + int.sizeof;
                break;
            case OpCode.SWITCH:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.GOTO:
                ip += 1 + uint.sizeof + ubyte.sizeof;
                break;
            case OpCode.THROW:
            case OpCode.RETHROW:
                ++ip;
                break;
            case OpCode.TRY:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.ENDTRY:
            case OpCode.LOADEXC:
                ++ip;
                break;
            case OpCode.CONCAT:
                ip += 1 + uint.sizeof;
                break;
            case OpCode.BITNOT:
            case OpCode.NOT:
            case OpCode.NEGATE:
            case OpCode.TYPEOF:
            case OpCode.POW:
            case OpCode.MUL:
            case OpCode.DIV:
            case OpCode.MOD:
            case OpCode.ADD:
            case OpCode.SUB:
            case OpCode.LT:
            case OpCode.LE:
            case OpCode.GT:
            case OpCode.GE:
            case OpCode.EQUALS:
            case OpCode.NEQUALS:
            case OpCode.BITAND:
            case OpCode.BITOR:
            case OpCode.BITXOR:
            case OpCode.AND:
            case OpCode.OR:
            case OpCode.TERN:
                ++ip;
                break;
            case OpCode.RETURN:
            case OpCode.HALT:
                ++ip;
                break;
            default:
                ++ip;
            }
        }
        writeln("=======================");
    }

    /// prints an individual instruction without moving the ip
    void printInstruction(in size_t ip, Chunk chunk)
    {
        auto op = cast(OpCode)chunk.bytecode[ip];
        switch(op)
        {
        case OpCode.NOP:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.CONST: {
            immutable constID = decode!uint(chunk.bytecode.ptr + ip + 1);
            printInstructionWithConstID(ip, op, constID, chunk);
            break;
        }
        case OpCode.CONST_0:
        case OpCode.CONST_1:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.PUSH: {
            immutable index = decode!int(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s index=%s", ip, op.opCodeToString, index);
            break;
        }
        case OpCode.POP:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.POPN: {
            immutable amount = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s amount=%s", ip, op.opCodeToString, amount);
            break;
        }
        case OpCode.SET: {
            immutable index = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s index=%s", ip, op.opCodeToString, index);
            break;
        }
        case OpCode.STACK: {
            immutable n = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s n=%s", ip, op.opCodeToString, n);
            break;
        }
        case OpCode.STACK_1:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.ARRAY: {
            immutable n = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s n=%s", ip, op.opCodeToString, n);
            break;
        }
        case OpCode.OBJECT: {
            immutable n = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s n=%s", ip, op.opCodeToString, n);
            break;
        }
        case OpCode.ITER:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.NEW: {
            immutable args = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s args=%s", ip, op.opCodeToString, args);
            break;
        }
        case OpCode.THIS:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.OPENSCOPE:
        case OpCode.CLOSESCOPE:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.DECLVAR: 
        case OpCode.DECLLET:
        case OpCode.DECLCONST: {
            immutable constID = decode!uint(chunk.bytecode.ptr + ip + 1);
            printInstructionWithConstID(ip, op, constID, chunk);
            break;
        }
        case OpCode.GETVAR:
        case OpCode.SETVAR: {
            immutable constID = decode!uint(chunk.bytecode.ptr + ip + 1);
            printInstructionWithConstID(ip, op, constID, chunk);
            break;
        }
        case OpCode.OBJSET:
        case OpCode.OBJGET:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.CALL: {
            immutable args = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s args=%s", ip, op.opCodeToString, args);
            break;
        }
        case OpCode.JMPFALSE: 
        case OpCode.JMP: {
            immutable jump = decode!int(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s jump=%s", ip, op.opCodeToString, jump);
            break;
        }
        case OpCode.SWITCH: {
            immutable def = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s default=%s", ip, op.opCodeToString, def);
            break;
        }
        case OpCode.GOTO: {
            immutable instruction = decode!uint(chunk.bytecode.ptr + ip + 1);
            immutable depth = decode!ubyte(chunk.bytecode.ptr + ip + 1 + uint.sizeof);
            writefln("%05d: %s instruction=%s, depth=%s", ip, op.opCodeToString, instruction, depth);
            break;
        }
        case OpCode.THROW:
        case OpCode.RETHROW:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.TRY: {
            immutable catchGoto = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s catch=%s", ip, op.opCodeToString, catchGoto);
            break;
        }
        case OpCode.ENDTRY:
        case OpCode.LOADEXC:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.CONCAT: {
            immutable n = decode!uint(chunk.bytecode.ptr + ip + 1);
            writefln("%05d: %s n=%s", ip, op.opCodeToString, n);
            break;
        }
        case OpCode.BITNOT:
        case OpCode.NOT:
        case OpCode.NEGATE:
        case OpCode.TYPEOF:
        case OpCode.POW:
        case OpCode.MUL:
        case OpCode.DIV:
        case OpCode.MOD:
        case OpCode.ADD:
        case OpCode.SUB:
        case OpCode.LT:
        case OpCode.LE:
        case OpCode.GT:
        case OpCode.GE:
        case OpCode.EQUALS:
        case OpCode.NEQUALS:
        case OpCode.BITAND:
        case OpCode.BITOR:
        case OpCode.BITXOR:
        case OpCode.AND:
        case OpCode.OR:
        case OpCode.TERN:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        case OpCode.RETURN:
        case OpCode.HALT:
            writefln("%05d: %s", ip, op.opCodeToString);
            break;
        default:
            writefln("%05d: ??? (%s)", ip, cast(ubyte)op);
        }  
    }

    /// run a chunk of bytecode with a given const table
    ScriptAny run(Chunk chunk)
    {
        _ip = 0;
        ubyte op;
        _stopped = false;
        _exc = null;
        _currentConstTable = chunk.constTable;
        while(_ip < chunk.bytecode.length && !_stopped)
        {
            op = chunk.bytecode[_ip];
            // debug printInstruction(_ip, chunk);
            _ops[op](this, chunk);
            // debug writefln("Stack: %s", _stack.array);
        }
        // if something is on the stack, that's the return value
        if(_stack.size > 0)
            return _stack.pop();
        _currentConstTable = null;
        return ScriptAny.UNDEFINED;
    }

    /// For calling script functions with call or apply.
    package(mildew) ScriptAny runFunction(ScriptFunction func, ScriptAny thisObj, ScriptAny[] args)
    {
        auto chunk = new Chunk();
        chunk.constTable = _currentConstTable;
        chunk.bytecode = func.compiled;
        ScriptAny result;
        writeln("Pushing call stack item");
        auto oldTryData = _tryData; // @suppress(dscanner.suspicious.unmodified)
        _tryData = [];
        immutable oldIP = _ip;
        auto oldEnv = _environment; // @suppress(dscanner.suspicious.unmodified)
        _environment = new Environment(func.closure);
        _environment.forceSetVarOrConst("this", thisObj, false);
        for(size_t i = 0; i < func.argNames.length; ++i)
        {
            if(i >= args.length)
                _environment.forceSetVarOrConst(func.argNames[i], ScriptAny.UNDEFINED, false);
            else
                _environment.forceSetVarOrConst(func.argNames[i], args[i], false);
        }
        try 
        {
            result = run(chunk);
        } 
        finally 
        {
            writeln("Popping call stack item");
            _environment = oldEnv;
            _ip = oldIP;
            _tryData = oldTryData;
        }
        return result;
    }

private:

    enum FuncCallType { NORMAL, NEW }
    struct CallData
    {
        FuncCallType fct;
        ubyte[] bc;
        size_t ip;
        Environment env;
        TryData[] tryData;
    }

    struct TryData
    {
        int depth;
        size_t stackSize;
        uint catchGoto;
    }

    void printInstructionWithConstID(size_t ip, OpCode op, uint constID, Chunk chunk)
    {
        writefln("%05d: %s #%s // <%s> %s", 
                ip, op.opCodeToString, constID, chunk.constTable.get(constID).typeToString(),
                chunk.constTable.get(constID));
    }

    Stack!CallData _callStack;
    Environment _environment;
    ConstTable _currentConstTable; // for running functions from call and apply
    ScriptRuntimeException _exc; // exception flag
    Environment _globals;
    size_t _ip;
    OpCodeFunction[ubyte.max + 1] _ops;
    Stack!ScriptAny _stack;
    TryData[] _tryData;
    /// stops the machine
    bool _stopped;
}

class VMException : Exception
{
    this(string msg, size_t iptr, OpCode op, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        ip = iptr;
        opcode = op;
    }

    override string toString() const
    {
        import std.format: format;
        return msg ~ " at instruction " ~ format("%x", ip) ~ " (" ~ opcode.opCodeToString ~ ")";
    }

    size_t ip;
    OpCode opcode;
}

unittest
{
    auto vm = new VirtualMachine(new Environment(null, "<global>"));
    auto chunk = new Chunk();

    ubyte[] getConst(T)(T value)
    {
        return encode(chunk.constTable.addValueUint(ScriptAny(value)));
    }

    ScriptAny native_testFunc(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError nfe)
    {
        writefln("The type of this is %s", thisObj.typeToString);
        for(size_t i = 0; i < args.length; ++i)
        {
            writefln("The type of arg #%s is %s", i, args[i].typeToString);
        }
        return ScriptAny(1000);
    }

    /*
0: this
1: const "foo"
6: const 123
11: const "eight"
16: array 3
21: iter
22: call 0
    */
    chunk.bytecode ~= OpCode.THIS;
    chunk.bytecode ~= OpCode.CONST ~ getConst("foo");
    chunk.bytecode ~= OpCode.CONST ~ getConst(123);
    chunk.bytecode ~= OpCode.CONST ~ getConst("eight");
    chunk.bytecode ~= OpCode.ARRAY ~ encode!uint(3);
    chunk.bytecode ~= OpCode.ITER;
    chunk.bytecode ~= OpCode.CALL ~ encode!uint(0);
    
    vm.printChunk(chunk);
    vm.run(chunk);
}