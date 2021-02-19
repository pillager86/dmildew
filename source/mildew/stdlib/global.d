/**
This module implements script functions that are stored in the global namespace such as parseInt and isdefined.

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
import mildew.interpreter;
import mildew.types;

/**
 * This is called by the interpreter's initializeStdlib method to store functions in the global namespace.
 * Documentation for these functions can be found at https://pillager86.github.io/dmildew/
 * Params:
 *  interpreter = The Interpreter instance to load the functions into.
 */
void initializeGlobalLibrary(Interpreter interpreter)
{
    // experimental: runFile
    interpreter.forceSetGlobal("runFile", new ScriptFunction("runFile", &native_runFile));
    interpreter.forceSetGlobal("isdefined", new ScriptFunction("isdefined", &native_isdefined));
    interpreter.forceSetGlobal("isFinite", new ScriptFunction("isFinite", &native_isFinite));
    interpreter.forceSetGlobal("isNaN", new ScriptFunction("isNaN", &native_isNaN));
    interpreter.forceSetGlobal("parseFloat", new ScriptFunction("parseFloat", &native_parseFloat));
    interpreter.forceSetGlobal("parseInt", new ScriptFunction("parseInt", &native_parseInt));
}

//
// Global method implementations
//

// experimental
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
        return env.getGlobalEnvironment.interpreter.evaluateFile(fileName, false, true);

    }
    catch(Exception ex)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny(ex.msg);
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