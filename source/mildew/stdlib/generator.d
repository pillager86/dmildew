/**
This module implements Generators for the Mildew scripting language.
See https://pillager86.github.io/dmildew/Generator.html for more details.

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
module mildew.stdlib.generator;

import std.concurrency;

import mildew.environment;
import mildew.exceptions;
import mildew.interpreter;
import mildew.types;
import mildew.vm;

/**
 * The Generator class implementation.
 */
class ScriptGenerator : Generator!ScriptAny
{
    /// ctor
    this(Environment env, ScriptFunction func, ScriptAny[] args, ScriptAny thisObj = ScriptAny.UNDEFINED)
    {
        // first get the thisObj
        bool _; // @suppress(dscanner.suspicious.unmodified)
        if(thisObj == ScriptAny.UNDEFINED)
        {
            if(func.boundThis)
            {
                thisObj = func.boundThis;
            }
            if(func.closure && func.closure.variableOrConstExists("this"))
            {
                thisObj = *func.closure.lookupVariableOrConst("this", _);
            }
            else if(env.variableOrConstExists("this"))
            {
                thisObj = *env.lookupVariableOrConst("this", _);
            }
            // else it's undefined and that's ok
        }

        // next get a VM copy that will live in the following closure
        if(env.g.interpreter is null)
            throw new Exception("Global environment has null interpreter");
        
        auto parentVM = env.g.interpreter.vm;
        auto childVM = parentVM.copy();

        _name = func.functionName;

        super({
            ScriptAny[string] map;
            map["__yield__"] = ScriptAny(new ScriptFunction("yield", &this.native_yield));
            map["yield"] = map["__yield__"];
            try 
            {
                _returnValue = childVM.runFunction(func, thisObj, args, map);
            }
            catch(ScriptRuntimeException ex)
            {
                this._markedAsFinished = true;
                parentVM.setException(ex);
            }
        });
    }

    override string toString() const 
    {
        return "Generator " ~ _name;
    }
package:

    ScriptAny native_yield(Environment env, ScriptAny* thisObj, ScriptAny[] args, ref NativeFunctionError nfe)
    {
        if(args.length < 1)
            .yield!ScriptAny(ScriptAny());
        else
            .yield!ScriptAny(args[0]);
        auto result = this._yieldValue;
        this._yieldValue = ScriptAny.UNDEFINED;
        if(_excFlag)
        {
            auto exc = _excFlag; // @suppress(dscanner.suspicious.unmodified)
            _excFlag = null;
            throw exc;
        }
        return result;
    }

private:
    string _name;
    bool _markedAsFinished = false;
    ScriptRuntimeException _excFlag;
    ScriptAny _yieldValue;
    ScriptAny _returnValue;
}

/**
 * Initializes the public Generator constructor. Generator functions are a first class language
 * feature so this is unnecessary. See https://pillager86.github.io/dmildew/Generator.html for how
 * to use the constructor and methods in Mildew.
 * Params:
 *  interpreter = The Interpreter instance to load the Generator constructor into.
 */
void initializeGeneratorLibrary(Interpreter interpreter)
{
    ScriptAny ctor = new ScriptFunction("Generator", &native_Generator_ctor, true);
    ctor["prototype"] = getGeneratorPrototype();
    ctor["prototype"]["constructor"] = ctor;
    interpreter.forceSetGlobal("Generator", ctor, false);
}

private ScriptObject _generatorPrototype;

/// Gets the Generator prototype. The VM uses this.
package(mildew) ScriptObject getGeneratorPrototype()
{
    if(_generatorPrototype is null)
    {
        _generatorPrototype = new ScriptObject("Generator", null);
        _generatorPrototype.addGetterProperty("name", new ScriptFunction("Generator.prototype.name",
                &native_Generator_p_name));
        _generatorPrototype["next"] = new ScriptFunction("Generator.prototype.next",
                &native_Generator_next);
        _generatorPrototype["return"] = new ScriptFunction("Generator.prototype.return",
                &native_Generator_return);
        _generatorPrototype["throw"] = new ScriptFunction("Generator.prototype.throw",
                &native_Generator_throw);
        _generatorPrototype.addGetterProperty("returnValue", new ScriptFunction("Generator.prototype.returnValue",
                &native_Generator_p_returnValue));
    }
    return _generatorPrototype;
}

private ScriptAny native_Generator_ctor(Environment env, ScriptAny* thisObj,
                                        ScriptAny[] args, ref NativeFunctionError nfe)
{
    if(args.length < 1 || args[0].type != ScriptAny.Type.FUNCTION)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny("First argument to new Generator() must exist and be a Function");
    }
    if(!thisObj.isObject)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    auto obj = thisObj.toValue!ScriptObject;
    obj.nativeObject = new ScriptGenerator(env, args[0].toValue!ScriptFunction, args[1..$]);
    return ScriptAny.UNDEFINED;
}

private ScriptAny native_Generator_p_name(Environment env, ScriptAny* thisObj,
                                          ScriptAny[] args, ref NativeFunctionError nfe)
{
    auto thisGen = thisObj.toNativeObject!ScriptGenerator;
    if(thisGen is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    return ScriptAny(thisGen._name);
}

/// The virtual machine uses this
package(mildew) ScriptAny native_Generator_next(Environment env, ScriptAny* thisObj,
                                ScriptAny[] args, ref NativeFunctionError nfe)
{
    auto thisGen = thisObj.toNativeObject!ScriptGenerator;
    if(thisGen is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    auto valueToYield = args.length > 0 ? args[0] : ScriptAny.UNDEFINED; // @suppress(dscanner.suspicious.unmodified)
    thisGen._yieldValue = valueToYield;

    if(thisGen._markedAsFinished)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny("Cannot call next on a finished Generator");
    }
    if(!thisGen.empty)
    {
        auto obj = new ScriptObject("iteration", null);
        obj["done"] = ScriptAny(false);
        obj["value"] = thisGen.front();
        try 
        {
            thisGen.popFront();
        }
        catch(ScriptRuntimeException ex)
        {
            thisGen._markedAsFinished = true;
            return ScriptAny.UNDEFINED;
        }
        return ScriptAny(obj);
    }
    else
    {
        thisGen._markedAsFinished = true;
        auto obj = new ScriptObject("iteration", null);
        obj["done"] = ScriptAny(true);
        return ScriptAny(obj);
    }
}

private ScriptAny native_Generator_return(Environment env, ScriptAny* thisObj,
                                          ScriptAny[] args, ref NativeFunctionError nfe)
{
    auto thisGen = thisObj.toNativeObject!ScriptGenerator;
    if(thisGen is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    ScriptAny retVal = args.length > 0 ? args[0] : ScriptAny.UNDEFINED; // @suppress(dscanner.suspicious.unmodified)
    if(thisGen._markedAsFinished)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny("Cannot call return on a finished Generator");
    }
    while(!thisGen.empty)
    {
        try 
        {
            thisGen.popFront();
        }
        catch(ScriptRuntimeException ex)
        {
            thisGen._markedAsFinished = true;
            return ScriptAny.UNDEFINED;
        }
    }
    thisGen._markedAsFinished = true;
    auto obj = new ScriptObject("iteration", null);
    obj["value"] = retVal;
    obj["done"] = ScriptAny(true);
    return ScriptAny(obj);
}

private ScriptAny native_Generator_throw(Environment env, ScriptAny* thisObj,
                                         ScriptAny[] args, ref NativeFunctionError nfe)
{
    auto thisGen = thisObj.toNativeObject!ScriptGenerator;
    if(thisGen is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    if(args.length < 1)
    {
        nfe = NativeFunctionError.WRONG_NUMBER_OF_ARGS;
        return ScriptAny.UNDEFINED;
    }
    if(thisGen._markedAsFinished)
    {
        nfe = NativeFunctionError.RETURN_VALUE_IS_EXCEPTION;
        return ScriptAny("Cannot call throw on a finished Generator");
    }
    auto exc = new ScriptRuntimeException("Generator exception");
    exc.thrownValue = args[0];
    thisGen._excFlag = exc;
    auto result = native_Generator_next(env, thisObj, [], nfe);
    return result;
}

private ScriptAny native_Generator_p_returnValue(Environment env, ScriptAny* thisObj,
                                               ScriptAny[] args, ref NativeFunctionError nfe)
{
    auto thisGen = thisObj.toNativeObject!ScriptGenerator;
    if(thisGen is null)
    {
        nfe = NativeFunctionError.WRONG_TYPE_OF_ARG;
        return ScriptAny.UNDEFINED;
    }
    return thisGen._returnValue;
}

