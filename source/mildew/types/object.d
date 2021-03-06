/**
This module implements ScriptObject, the base class for builtin Mildew objects.

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
module mildew.types.object;

/**
 * General Object class. Similar to JavaScript, this class works as a dictionary but 
 * the keys must be strings. Native D objects can be stored in any ScriptObject or derived 
 * class by assigning it to its nativeObject field. This is also the base class for
 * arrays, strings, and functions so that those script values can have dictionary entries
 * assigned to them as well.
 */
class ScriptObject
{
    import mildew.types.any: ScriptAny;
    import mildew.types.func: ScriptFunction;
public:
    /**
     * Constructs a new ScriptObject that can be stored inside ScriptValue.
     * Params:
     *  typename = This does not have to be set to a meaningful value but constructors (calling script functions
     *             with the new keyword) set this value to the name of the function.
     *  proto = The object's __proto__ property. If a value is not found inside the current object's table, a chain
     *          of prototypes is searched until reaching a null prototype. If this parameter is null, the value is
     *          set to Object.prototype
     *  native = A ScriptObject can contain a native D object that can be accessed later. This is used for binding
     *           D classes.
     */
    this(in string typename, ScriptObject proto, Object native = null)
    {
        import mildew.types.bindings: getObjectPrototype;
        _name = typename;
        if(proto !is null)
            _prototype = proto;
        else
            _prototype = getObjectPrototype;
        _nativeObject = native;
    }

    /**
     * Empty constructor that leaves prototype, and nativeObject as null.
     */
    this(in string typename)
    {
        _name = typename;
    }

    /// name property
    string name() const { return _name; }

	/// getters property
	auto getters() { return _getters; }
	/// setters property
	auto setters() { return _setters; }

    /// prototype property
    auto prototype() { return _prototype; }

    /// prototype property (setter)
    auto prototype(ScriptObject proto) { return _prototype = proto; }

    /// This property provides direct access to the dictionary
    auto dictionary() { return _dictionary; }

    /**
     * Add a getter. Getters should be added to a constructor function's "prototype" field
     */
    void addGetterProperty(in string propName, ScriptFunction getter)
    {
        _getters[propName] = getter;
    }

    /**
     * Add a setter. Setters should be added to a constructor function's "prototype" field
     */
    void addSetterProperty(in string propName, ScriptFunction setter)
    {
        _setters[propName] = setter;
    }

    /**
     * Looks up a field through the prototype chain. Note that this does not call any getters because
     * it is not possible to pass an Environment to opIndex.
     */
    ScriptAny lookupField(in string name)
    {
        if(name == "__proto__")
            return ScriptAny(_prototype);
        if(name == "__super__")
        {
            //the super non-constructor expression should translate to "this.__proto__.constructor.__proto__.prototype"
            if(_prototype && _prototype["constructor"])
            {
                // .__proto__.constructor
                auto protoCtor = _prototype["constructor"].toValue!ScriptObject;
                if(protoCtor && protoCtor._prototype)
                {
                    return protoCtor._prototype["prototype"];
                }
            }
        }
        if(name in _dictionary)
            return _dictionary[name];
        if(_prototype !is null)
            return _prototype.lookupField(name);
        return ScriptAny.UNDEFINED;
    }

    /**
     * Shorthand for lookupField.
     */
    ScriptAny opIndex(in string index)
    {
        return lookupField(index);
    }

    /**
     * Comparison operator
     */
    int opCmp(const ScriptObject other) const
    {
        if(other is null)
            return 1;
        
        if(_dictionary == other._dictionary)
            return 0;
        
        if(_dictionary.keys < other._dictionary.keys)
            return -1;
        else if(_dictionary.keys > other._dictionary.keys)
            return 1;
        else if(_dictionary.values < other._dictionary.values)
            return -1;
        else if(_dictionary.values > other._dictionary.values)
            return 1;
        else
        {
            if(_prototype is null && other._prototype is null)
                return 0;
            else if(_prototype is null && other._prototype !is null)
                return -1;
            else if(_prototype !is null && other._prototype is null)
                return 1;
            else
                return _prototype.opCmp(other._prototype);
        }
    }

    /**
     * opEquals
     */
    bool opEquals(const ScriptObject other) const
    {
        // TODO rework this to account for __proto__
        return opCmp(other) == 0;
    }

    /// toHash
    override size_t toHash() const @safe nothrow
    {
        return typeid(_dictionary).getHash(&_dictionary);
    }

    /**
     * Assigns a field to the current object. This does not call any setters.
     */
    ScriptAny assignField(in string name, ScriptAny value)
    {
        if(name == "__proto__")
        {
            _prototype = value.toValue!ScriptObject;
        }
        else if(name == "__super__")
        {
            return value; // this can't be assigned directly
        }
        else
        {
            _dictionary[name] = value;
        }
        return value;
    }

    /**
     * Determines if there is a getter for a given property
     */
    bool hasGetter(in string propName)
    {
        auto objectToSearch = this;
        while(objectToSearch !is null)
        {
            if(propName in objectToSearch._getters)
                return true;
            objectToSearch = objectToSearch._prototype;
        }
        return false;
    }

    /**
     * Determines if there is a setter for a given property
     */
    bool hasSetter(in string propName)
    {
        auto objectToSearch = this;
        while(objectToSearch !is null)
        {
            if(propName in objectToSearch._setters)
                return true;
            objectToSearch = objectToSearch._prototype;
        }
        return false;
    }

    /**
     * Find a getter in the prototype chain
     */
    ScriptFunction findGetter(in string propName)
    {
        auto objectToSearch = this;
        while(objectToSearch !is null)
        {
            if(propName in objectToSearch._getters)
                return objectToSearch._getters[propName];
            objectToSearch = objectToSearch._prototype;
        }
        return null;
    }

    /**
     * Find a setter in the prototype chain
     */
     ScriptFunction findSetter(in string propName)
     {
        auto objectToSearch = this;
        while(objectToSearch !is null)
        {
            if(propName in objectToSearch._setters)
                return objectToSearch._setters[propName];
            objectToSearch = objectToSearch._prototype;
        }
        return null;
     }

    /**
     * Shorthand for assignField
     */
    ScriptAny opIndexAssign(T)(T value, in string index)
    {
        static if(is(T==ScriptAny))
            return assignField(index, value);
        else
        {
            ScriptAny any = value;
            return assignField(index, any);
        }
    }

    /**
     * Returns a property descriptor without searching the prototype chain. The object returned is
     * an object possibly containing get, set, or value fields.
     * Returns:
     *  A ScriptObject whose dictionary contains possible "get", "set", and "value" fields.
     */
    ScriptObject getOwnPropertyOrFieldDescriptor(in string propName)
    {
        ScriptObject property = new ScriptObject("property", null);
        // find the getter
        auto objectToSearch = this;
        if(propName in objectToSearch._getters)
            property["get"] = objectToSearch._getters[propName];
        if(propName in objectToSearch._setters)
            property["set"] = objectToSearch._setters[propName];
        if(propName in objectToSearch._dictionary)
            property["value"] = _dictionary[propName];
        objectToSearch = objectToSearch._prototype;
        return property;
    }

    /**
     * Get all fields and properties for this object without searching the prototype chain.
     * Returns:
     *  A ScriptObject whose dictionary entry keys are names of properties and fields, and the value
     *  of which is a ScriptObject containing possible "get", "set", and "value" fields.
     */
    ScriptObject getOwnFieldOrPropertyDescriptors()
    {
        auto property = new ScriptObject("descriptors", null);
        foreach(k,v ; _dictionary)
        {
            auto descriptor = new ScriptObject("descriptor", null);
            descriptor["value"] = v;
            property[k] = descriptor;
        }
        foreach(k,v ; _getters)
        {
            auto descriptor = new ScriptObject("descriptor", null);
            descriptor["get"] = v;
            property[k] = descriptor;
        }
        foreach(k, v ; _setters)
        {
            auto descriptor = property[k].toValue!ScriptObject;
            if(descriptor is null)
                descriptor = new ScriptObject("descriptor", null);
            descriptor["set"] = v;
            property[k] = descriptor;
        }
        return property;
    }

    /**
     * Tests whether or not a property or field exists in this object without searching the
     * __proto__ chain.
     */
    bool hasOwnFieldOrProperty(in string propOrFieldName)
    {
        if(propOrFieldName in _dictionary)
            return true;
        if(propOrFieldName in _getters)
            return true;
        if(propOrFieldName in _setters)
            return true;
        return false;
    }

    /**
     * If a native object was stored inside this ScriptObject, it can be retrieved with this function.
     * Note that one must always check that the return value isn't null because all functions can be
     * called with invalid "this" objects using Function.prototype.call.
     */
    T nativeObject(T)() const
    {
        static if(is(T == class) || is(T == interface))
            return cast(T)_nativeObject;
        else
            static assert(false, "This method can only be used with D classes and interfaces");
    }

    /**
     * Native object can also be written because this is how binding works. Constructors
     * receive a premade ScriptObject as the "this" with the name and prototype already set.
     * Native D constructor functions have to set this property.
     */
    T nativeObject(T)(T obj)
    {
        static if(is(T == class) || is(T == interface))
            return cast(T)(_nativeObject = obj);
        else
            static assert(false, "This method can only be used with D classes and interfaces");
    }

    /**
     * Returns a string with JSON like formatting representing the object's key-value pairs as well as
     * any nested objects. In the future this will be replaced and an explicit function call will be
     * required to print this detailed information.
     */
    override string toString() const
    {
        if(nativeObject!Object !is null)
            return nativeObject!Object.toString();
        return _name ~ " " ~ formattedString();
    }
protected:

    /// The dictionary of key-value pairs
    ScriptAny[string] _dictionary;

    /// The lookup table for getters
    ScriptFunction[string] _getters;

    /// The lookup table for setters
    ScriptFunction[string] _setters;

private:

    // TODO complete rewrite
    string formattedString(int indent = 0) const
    {
        immutable indentation = "    ";
        auto result = "{";
        size_t counter = 0;
        immutable keyLength = _dictionary.keys.length;
        foreach(k, v ; _dictionary)
        {
            for(int i = 0; i < indent; ++i)
                result ~= indentation;
            result ~= k ~ ": ";
            if(v.type == ScriptAny.Type.OBJECT)
            {
                if(!v.isNull)
                    result ~= v.toValue!ScriptObject().formattedString(indent+1);
                else
                    result ~= "<null object>";
            }
            else if(v.type == ScriptAny.Type.STRING)
            {
                result ~= "\"" ~ v.toString() ~ "\"";
            }
            else
                result ~= v.toString();
            if(counter < keyLength - 1)
                result ~= ", ";
            ++counter;
        }
        // for(int i = 0; i < indent; ++i)
        //    result ~= indentation;
        result ~= "}";
        return result;
    }

    /// type name (Function or whatever)
    string _name;
    /// it can also hold a native object
    Object _nativeObject;
    /// prototype 
    ScriptObject _prototype = null;
}
