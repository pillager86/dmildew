/**
This module implements script functions that are stored in the global namespace.
See https://pillager86.github.io/dmildew/global.html for more information.

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
module mildew.stdlib.global;

import mildew.environment;
import mildew.exceptions;
import mildew.interpreter;
import mildew.types;

/**
 * This is called by the interpreter's initializeStdlib method to store functions in the global namespace.
 * Documentation for these functions can be found at https://pillager86.github.io/dmildew/global.html
 * Params:
 *  interpreter = The Interpreter instance to load the functions into.
 */
void initializeGlobalLibrary(Interpreter interpreter)
{
    // experimental: runFile
    interpreter.forceSetGlobal("runFile", new ScriptFunction("runFile", &native_runFile));
    interpreter.forceSetGlobal("clearImmediate", new ScriptFunction("clearImmediate", &native_clearImmediate));
    interpreter.forceSetGlobal("clearTimeout", new ScriptFunction("clearTimeout", &native_clearTimeout));
    interpreter.forceSetGlobal("decodeURI", new ScriptFunction("decodeURI", &native_decodeURI));
    interpreter.forceSetGlobal("decodeURIComponent", new ScriptFunction("decodeURIComponent", 
            &native_decodeURIComponent));
    interpreter.forceSetGlobal("encodeURI", new ScriptFunction("encodeURI", &native_encodeURI));
    interpreter.forceSetGlobal("encodeURIComponent", new ScriptFunction("encodeURIComponent", 
            &native_encodeURIComponent));
    interpreter.forceSetGlobal("isdefined", new ScriptFunction("isdefined", &native_isdefined));
    interpreter.forceSetGlobal("isFinite", new ScriptFunction("isFinite", &native_isFinite));
    interpreter.forceSetGlobal("isNaN", new ScriptFunction("isNaN", &native_isNaN));
    interpreter.forceSetGlobal("parseFloat", new ScriptFunction("parseFloat", &native_parseFloat));
    interpreter.forceSetGlobal("parseInt", new ScriptFunction("parseInt", &native_parseInt));
    interpreter.forceSetGlobal("setImmediate", new ScriptFunction("setImmediate", &native_setImmediate));
    interpreter.forceSetGlobal("setTimeout", new ScriptFunction("setTimeout", &native_setTimeout));
}

//
// Global method implementations
//

// experimental DO NOT USE
private ScriptAny native_runFile(Environment env, ScriptAny* thisObj,
                                 ScriptAny[] args, ref NativeFunctionError nfe)
{
    if(args.length < 1)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    auto fileName = args[0].toString();
    try 
    {
        return env.g.interpreter.evaluateFile(fileName);

    }
    catch(Exception ex)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny(ex.msg);
    }
}

private ScriptAny native_clearImmediate(Environment env, ScriptAny* thisObj,
                                      ScriptAny[] args, ref NativeFunctionError nfe)
{
    import mildew.vm.virtualmachine: VirtualMachine;
    import mildew.vm.fiber: ScriptFiber;

    if(args.length < 1)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    auto sfib = args[0].toNativeObject!ScriptFiber;
    if(sfib is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    if(sfib.toString() != "Immediate")
        return ScriptAny(false);
    return ScriptAny(env.g.interpreter.vm.removeFiber(sfib));
}

private ScriptAny native_clearTimeout(Environment env, ScriptAny* thisObj,
                                      ScriptAny[] args, ref NativeFunctionError nfe)
{
    import mildew.vm.virtualmachine: VirtualMachine;
    import mildew.vm.fiber: ScriptFiber;

    if(args.length < 1)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    auto sfib = args[0].toNativeObject!ScriptFiber;
    if(sfib is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    if(sfib.toString() != "Timeout")
        return ScriptAny(false);
    return ScriptAny(env.g.interpreter.vm.removeFiber(sfib));
}

private ScriptAny native_decodeURI(Environment env, ScriptAny* thisObj,
                                   ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.uri: decode, URIException;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    try 
    {
        return ScriptAny(decode(args[0].toString()));
    }
    catch(URIException ex)
    {
        throw new ScriptRuntimeException(ex.msg);
    }
}

private ScriptAny native_decodeURIComponent(Environment env, ScriptAny* thisObj,
                                            ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.uri: decodeComponent, URIException;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    try 
    {
        return ScriptAny(decodeComponent(args[0].toString()));
    }
    catch(URIException ex)
    {
        throw new ScriptRuntimeException(ex.msg);
    }
}

private ScriptAny native_encodeURI(Environment env, ScriptAny* thisObj,
                                   ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.uri: encode, URIException;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    try 
    {
        return ScriptAny(encode(args[0].toString()));
    }
    catch(URIException ex)
    {
        throw new ScriptRuntimeException(ex.msg);
    }
}

private ScriptAny native_encodeURIComponent(Environment env, ScriptAny* thisObj,
                                            ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.uri: encodeComponent, URIException;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    try 
    {
        return ScriptAny(encodeComponent(args[0].toString()));
    }
    catch(URIException ex)
    {
        throw new ScriptRuntimeException(ex.msg);
    }
}

private ScriptAny native_isdefined(Environment env, 
                                   ScriptAny* thisObj, 
                                   ScriptAny[] args, 
                                   ref NativeFunctionError nfe)
{
    if(args.length < 1)
        return ScriptAny(false);
    auto varToLookup = args[0].toString();
    return ScriptAny(env.variableOrConstExists(varToLookup));
}

private ScriptAny native_isFinite(Environment env, ScriptAny* thisObj, 
                                  ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.math: isFinite;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    if(!args[0].isNumber)
        return ScriptAny.UNDEFINED;
    immutable value = args[0].toValue!double;
    return ScriptAny(isFinite(value));
}

private ScriptAny native_isNaN(Environment env, ScriptAny* thisObj,
                               ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.math: isNaN;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    if(!args[0].isNumber)
        return ScriptAny(true);
    immutable value = args[0].toValue!double;
    return ScriptAny(isNaN(value));
}

private ScriptAny native_parseFloat(Environment env, ScriptAny* thisObj,
                                    ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.conv: to, ConvException;
    if(args.length < 1)
        return ScriptAny(double.nan);
    auto str = args[0].toString();
    try 
    {
        immutable value = to!double(str);
        return ScriptAny(value);
    }
    catch(ConvException)
    {
        return ScriptAny(double.nan);
    }
}

private ScriptAny native_parseInt(Environment env, ScriptAny* thisObj,
                                  ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.conv: to, ConvException;
    if(args.length < 1)
        return ScriptAny.UNDEFINED;
    auto str = args[0].toString();
    immutable radix = args.length > 1 ? args[1].toValue!int : 10;
    try 
    {
        immutable value = to!long(str, radix);
        return ScriptAny(value);
    }
    catch(ConvException)
    {
        return ScriptAny.UNDEFINED;
    }
}

private ScriptAny native_setImmediate(Environment env, ScriptAny* thisObj,
                                      ScriptAny[] args, ref NativeFunctionError nfe)
{
    import mildew.types.bindings: getLocalThis;
    // all environments are supposed to be linked to the global one. if not, there is a bug
    auto vm = env.g.interpreter.vm;
    if(args.length < 1)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    auto func = args[0].toValue!ScriptFunction;
    if(func is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    args = args[1..$];
    auto thisToUse = args.length > 0 ? getLocalThis(env, args[0]) : ScriptAny.UNDEFINED;
    ScriptFunction funcToAsync = new ScriptFunction(func.functionName, 
        delegate ScriptAny(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError) {
            return vm.runFunction(func, thisToUse, args);
    });
    auto retVal = vm.addFiberFirst("Immediate", funcToAsync, thisToUse, args);
    return ScriptAny(retVal);
}

private ScriptAny native_setTimeout(Environment env, ScriptAny* thisObj,
                                    ScriptAny[] args, ref NativeFunctionError nfe)
{
    import std.datetime: dur, Clock;
    import std.concurrency: yield;
    import mildew.types.bindings: getLocalThis;

    // all environments are supposed to be linked to the global one. if not, there is a bug
    auto vm = env.g.interpreter.vm;
    if(args.length < 2)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    auto func = args[0].toValue!ScriptFunction;
    if(func is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    auto timeout = args[1].toValue!size_t;
    args = args[2..$];
    auto thisToUse = args.length > 0 ? getLocalThis(env, args[0]) : ScriptAny.UNDEFINED;
    ScriptFunction funcToAsync = new ScriptFunction(func.functionName, 
        delegate ScriptAny(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError) {
            immutable start = Clock.currStdTime() / 10_000;
            long current = start;
            while(current - start <= timeout)
            {
                yield();
                current = Clock.currStdTime() / 10_000;
            }
            return vm.runFunction(func, thisToUse, args);
    });

    auto retVal = vm.addFiber("Timeout", funcToAsync, thisToUse, args);
    return ScriptAny(retVal);
}