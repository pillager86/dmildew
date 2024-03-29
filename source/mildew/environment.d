/**
This module implements the Environment class.

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
module mildew.environment;

import std.container.rbtree;

import mildew.types.any;
import mildew.interpreter: Interpreter;

private alias VariableTable = ScriptAny[string];

/**
 * Holds the variables and consts of a script stack frame. The global environment can be accessed by
 * climbing the Environment.parent chain until reaching the Environment whose parent is null. This allows
 * native functions to define local and global variables. Note that calling a native function does
 * not create a stack frame so one could write a native function that adds local variables to the
 * stack frame where it was called.
 */
class Environment
{
public:
    /**
     * Constructs a new Environment. This constructor cannot be used to create the global Environment.
     * Params:
     *  par = The parent environment, which should be null when the global environment is created
     *  nam = The name of the environment. When script functions are called this is set to the name
     *        of the function being called.
     */
    this(Environment par = null, in string nam = "<environment>")
    {
        _parent = par;
        _name = nam;
    }

    /**
     * Constructs a global environment
     */
    this(Interpreter interpreter)
    {
        _parent = null;
        _name = "<global>";
        _interpreter = interpreter;
    }

    /**
     * Attempts to look up existing variable or const throughout the stack. If found, returns a pointer to the 
     * variable location, and if it is const, sets isConst to true. Note, this pointer should not be stored by 
     * native functions because the variable table may be modified between function calls.
     * Params:
     *  name = The name of the variable to look up.
     *  isConst = Whether or not the found variable is constant. Will remain false if variable is not found
     * Returns:
     *  A pointer to the located variable, or null if the variable was not found. If this value is needed for later
     *  the caller should make a copy of the variable immediately.
     */
    ScriptAny* lookupVariableOrConst(in string varName, out bool isConst)
    {
        auto environment = this;
        while(environment !is null)
        {
            if(varName in environment._constTable)
            {
                isConst = true;
                return (varName in environment._constTable);
            }
            if(varName in environment._varTable)
            {
                isConst = false;
                return (varName in environment._varTable);
            }
            environment = environment._parent;
        }
        isConst = false;
        return null; // found nothing
    }

    /**
     * Removes a variable from anywhere on the Environment stack it is located. This function cannot
     * be used to unset consts.
     * Params:
     *  name = The name of the variable.
     */
    void unsetVariable(in string name)
    {
        auto environment = this;
        while(environment !is null)
        {
            if(name in environment._varTable)
            {
                environment._varTable.remove(name);
                return;
            }
            environment = environment._parent;
        }
    }

    /** 
     * Attempt to declare and assign a new variable in the current environment. Returns false if it already exists.
     * Params:
     *  nam = the name of the variable to set.
     *  value = the initial value of the variable. This can be ScriptAny.UNDEFINED
     *  isConst = whether or not the variable was declared as a const
     * Returns:
     *  True if the declaration was successful, otherwise false.
     */
    bool declareVariableOrConst(in string nam, ScriptAny value, in bool isConst)
    {
        if(nam in _varTable || nam in _constTable)
            return false;
        
        if(isConst)
        {
            _constTable[nam] = value;
        }
        else
        {
            _varTable[nam] = value;
        }
        return true;
    }

    /**
     * Searches the entire Environment stack for a variable starting with the current environment and climbing the parent
     * chain.
     * Params:
     *  name = The name of the variable to look for.
     * Returns:
     *  True if the variable is found, otherwise false.
     */
    bool variableOrConstExists(in string name)
    {
        auto environment = this;
        while(environment !is null)
        {
            if(name in environment._constTable)
                return true;
            if(name in environment._varTable)
                return true;
            environment = environment._parent;
        }
        return false;
    }

    /**
     * Attempts to reassign a variable anywhere in the stack and returns a pointer to the variable or null
     * if the variable doesn't exist or is const. If the failure is due to const, failedBecauseConst is
     * set to true. Note: this pointer should not be stored by native functions due to modifications
     * to the variable table that may invalidate it and result in undefined behavior.
     * Params:
     *  name = The name of the variable to reassign.
     *  newValue = The value to assign. If this is undefined and the variable isn't const, the variable
     *             will be deleted from the table where it is found.
     *  failedBecauseConst = If the reassignment fails due to the variable being a const, this is set to true
     * Returns:
     *  A pointer to the variable in the table where it is found, or null if it was const or not located.
     */
    ScriptAny* reassignVariable(in string name, ScriptAny newValue, out bool failedBecauseConst)
    {
        bool isConst; // @suppress(dscanner.suspicious.unmodified)
        auto scriptAnyPtr = lookupVariableOrConst(name, isConst);
        if(scriptAnyPtr == null)
        {
            failedBecauseConst = false;
            return null;
        }
        if(isConst)
        {
            failedBecauseConst = true;
            return null;
        }
        *scriptAnyPtr = newValue;
        failedBecauseConst = false;
        return scriptAnyPtr;
    }

    /**
     * Force sets a variable or const no matter if the variable was declared already or is const. This is
     * used by the host application to set globals or locals.
     * Params:
     *  name = The name of the variable or const
     *  value = The value of the variable
     *  isConst = Whether or not the variable should be considered const and unable to be overwritten by the script
     */
    void forceSetVarOrConst(in string name, ScriptAny value, bool isConst)
    {
        if(isConst)
        {
            _constTable[name] = value;
        }
        else
        {
            _varTable[name] = value;
        }
    }

    /**
     * Forces the removal of a const or variable in the current environment.
     */
    void forceRemoveVarOrConst(in string name)
    {
        if(name in _constTable)
            _constTable.remove(name);
        if(name in _varTable)
            _varTable.remove(name);
    }

    /// climb environment stack until finding one without a parent
    Environment g()
    {
        Environment c = this;
        while(c._parent !is null)
        {
            c = c._parent;
        }
        return c;
    }

    /// Retrieves the interpreter object from the top level environment
    Interpreter interpreter()
    {
        auto search = this;
        while(search !is null)
        {
            if(search._interpreter !is null)
                return search._interpreter;
            search = search._parent;
        }
        return null;
    }

    /// returns the parent Environment
    Environment parent()
    {
        return _parent;
    }

    /// Returns the depth from this Environment to the root Environment
    size_t depth()
    {
        size_t d = 0;
        auto env = _parent;
        while(env !is null)
        {
            ++d;
            env = env._parent;
        }
        return d;
    }

    /// returns the name of the Environment
    string name() const
    {
        return _name;
    }

    /// Returns a string representing the type and name
    override string toString() const
    {
        return "Environment " ~ _name;
    }

    /// Returns the level of depth, relative to this Environment, 0-N for a variable location, or -1 if not found
    int varDepth(string varName, out bool isConst)
    {
        int depth = 0;
        auto env = this;
        isConst = false;
        while(env !is null)
        {
            if(varName in env._constTable)
            {
                isConst = true;
                return depth;
            }
            if(varName in env._varTable)
                return depth;
            env = env._parent;
            ++depth;
        }
        return -1;
    }

private:

    /// parent environment. null if this is the global environment
    Environment _parent;
    /// name of environment
    string _name;
    /// holds variables
    VariableTable _varTable;
    /// holds consts, which can be shadowed by other consts or lets
    VariableTable _constTable;
    /// holds a list of labels
    deprecated auto _labelList = new RedBlackTree!string;
    /// Interpreter object can be held by global environment
    Interpreter _interpreter;
}