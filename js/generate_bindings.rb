#/usr/bin/env ruby
# script to generate bindings using the cocos2d.xml generated by clang
# in order to get the C++ info

require 'rubygems'
require 'nokogiri'
require 'fileutils'
# require 'ruby-debug'

class String
  def uncapitalize
    self[0].downcase + self[1, length]
  end

  def capitalize
    self[0].upcase + self[1, length]
  end
end

class CppMethod
  attr_reader :name, :static, :num_arguments, :type

  def initialize(node, klass, bindings_generator)
    @name = node['name']
    @static = node['static'] == "1" ? true : false
    @num_arguments = node['num_args'].to_i
    @arguments = []
    v = {:type => node['type']}
    bindings_generator.real_type(v)
    @type = v[:type]
    @klass = klass
    (node / "ParmVar").each do |par|
      @arguments << {
        :name => par['name'],
        :type => par['type']
      }
    end
  end

  # returns the native, original signature, useful for overriden the method
  def native_signature(impl = false)
    type = {}
    signature = ""
    if @klass.generator.find_type(@type, type)
      signature << "#{type[:name]} "
      if impl
        signature << "S_#{@klass.name}::#{@name}"
      else
        signature << @name
      end
      signature << "("
      args = []
      @arguments.each do |arg|
        type = {}
        arg_str = ""
        if @klass.generator.find_type(arg[:type], type)
          pointer = type[:pointer] ? "*" : ""
          arg_str << "#{type[:name]}#{pointer} #{arg[:name]}"
        end
        args << arg_str
      end
      signature << args.join(", ")
      signature << ")"
    end
  end

  # handy for setters
  def first_argument_type
    return nil if @arguments.empty?
    type = {}
    if @klass.generator.find_type(@arguments[0][:type], type)
      return type
    end
    return nil
  end

  def convert_arguments_and_call(str, indent_level = 0)
    indent = "\t" * indent_level
    str << "#{indent}if (argc == #{@num_arguments}) {\n"
    args_str = ""
    call_params = []
    convert_params = []
    self_str = @static ? "#{@klass.name}::" : "self->"
    # debugger if @name == "didAccelerate"
    @arguments.each_with_index do |arg, i|
      type = {}
      args_str << @klass.generator.arg_format(arg, type)
      # fundamental type
      if type[:fundamental] && !type[:pointer]
        # fix for JS_ConvertArguments (it only accepts doubles)
        type[:name] = "double" if type[:name] == "float"
        str << "#{indent}\t#{type[:name]} arg#{i};\n"
        call_params << [type[:name], "arg#{i}"]
        convert_params << "&arg#{i}"
      else
        if type[:pointer]
          type = @klass.generator.pointer_types[arg[:type]]
          deref = false
        else
          deref = true
        end
        if type[:name] =~ /char/
          str << "#{indent}\tJSString *arg#{i};\n"
        else
          str << "#{indent}\tJSObject *arg#{i};\n"
        end
        if type[:name].nil? && !deref
          if arg[:name] =~ /dictionary/i
            if @name.downcase =~ /spriteframe/i
              type[:name] = "CCDictionary<std::string,CCSpriteFrame*>"
            else
              type[:name] = "CCDictionary<std::string,CCObject*>"
            end
          elsif arg[:name] =~ /array/i
            type[:name] = "CCMutableArray<CCObject*>"
          elsif arg[:name] =~ /frames/i
            type[:name] = "CCMutableArray<CCSpriteFrame*>"
          else
            raise "unknown pointer, please check - might be a weird template (in #{@name}, #{@klass.name})"
          end
        end
        call_params << [type[:name], ((deref ? "*" : "") + "narg#{i}")]
        convert_params << "&arg#{i}"
      end
    end
    convert_str = (convert_params.size > 0 ? ", #{convert_params.join(', ')}" : "")
    str << "#{indent}\tJS_ConvertArguments(cx, #{@num_arguments}, JS_ARGV(cx, vp), \"#{args_str}\"#{convert_str});\n"
    # conver the JSObjects to the proper native object
    args_str.split(//).each_with_index do |type, i|
      if type == "o"
        ntype = call_params[i][0]
        str << "#{indent}\t#{ntype}* narg#{i}; JSGET_PTRSHELL(#{ntype}, narg#{i}, arg#{i});\n"
      elsif type == "S"
        str << "#{indent}\tchar *narg#{i} = JS_EncodeString(cx, arg#{i});\n"
      end
    end
    # do the call
    type = {}
    if @klass.generator.find_type(@type, type)
      ret = ""
      void_ret = ""
      ref = false
      # debugger if @name == "initWithAnimation"
      unless type[:fundamental] && type[:name] == "void"
        ret = type[:name]
        ref = type[:pointer].nil? && type[:fundamental].nil?
        ret += "#{type[:fundamental] ? "" : "*"} ret = "
      else
        void_ret = "JS_SET_RVAL(cx, vp, JSVAL_TRUE);"
      end
      if ref
        str << "#{indent}\t#{ret}new #{type[:name]}(#{self_str}#{@name}(#{call_params.map {|p| p[1]}.join(', ')}));\n"
        type[:pointer] = true
      else
        str << "#{indent}\t#{ret}#{self_str}#{@name}(#{call_params.map {|p| p[1]}.join(', ')});\n"
        # test for null pointers
        if type[:pointer]
          str << "#{indent}\tif (ret == NULL) {\n"
          str << "#{indent}\t\tJS_SET_RVAL(cx, vp, JSVAL_NULL);\n"
          str << "#{indent}\t\treturn JS_TRUE;\n"
          str << "#{indent}\t}\n"
        end
      end
      str << "#{indent}\t" << @klass.convert_value_to_js({:type => @type, :pointer => type[:pointer]}, "ret", "vp", indent_level+1, "") << "\n"
      str << "#{indent}\t#{void_ret}\n"
    else
      str << "#{indent}\t//INVALID RETURN TYPE #{@type}\n"
    end
    str << "#{indent}\treturn JS_TRUE;\n"
    str << "#{indent}}\n"
  end
end

class CppClass
  attr_reader :name, :generator, :singleton, :methods, :properties

  # initialize the class with a nokogiri node
  def initialize(node, bindings_generator)
    @generator = bindings_generator
    @parents = []
    @properties = {}
    @methods = {}
    # the constructor/init methods
    @constructors = []
    @init_methods = []
    @singleton = false

    @name = node['name']
    prefixless_name = @name.gsub(/^CC/, '').downcase
    # puts node if @name == "CCPoint"

    # test for super classes
    (node / "Base").each do |base|
      klass = bindings_generator.classes[base['id']]
      @parents << klass
    end

    (node / "Field").each do |field|
      # puts field if @name == "CCPoint"
      md = field['name'].match(/m_(\w+)/)
      if md
        # might be m_var or m_([nfpbt])Var
        if md_ = md[1].match(/[nfpbtus]([A-Z]\w*)/)
          field_name = md_[1].uncapitalize
        else
          field_name = md[1].uncapitalize
        end
        @properties[field_name] = {:type => field['type'], :getter => nil, :setter => nil, :requires_accessor => true}
      else
        @properties[field['name']] = {:type => field['type']} if field['access'] == "public"
      end
    end

    (node / "CXXConstructor").each do |method|
      @constructors << CppMethod.new(method, self, bindings_generator)
    end

    (node / "CXXMethod").each do |method|
      # the accessors
      next if method['access'] != "public"
      # no support for "node" or "descrition" (yet)
      next if method['name'].match(/^(node|description|copyWithZone|mutableCopy)/)
      next if method['name'].match(/step|update/) && (@name == "CCAction" || @parents.map { |n| n[:name] }.include?("CCAction"))

      # mark as singleton (produce no constructor code)
      @singleton = true if method['name'].match(/^shared.*#{prefixless_name}/i)

      if md = method['name'].match(/(get|set)(\w+)/)
        action = md[1]
        field_name = md[2].uncapitalize
        prop = @properties[field_name]
        if prop
          prop[:getter] = CppMethod.new(method, self, bindings_generator) if action == "get" && method['num_args'] == "0"
          prop[:setter] = CppMethod.new(method, self, bindings_generator) if action == "set" && method['num_args'] == "1"
        end
      # everything else but operator overloading
      elsif method['name'] !~ /^operator/
        m = CppMethod.new(method, self, bindings_generator)
        @methods[m.name] ||= []
        @methods[m.name] << m
      end # if (accessor)
    end
  end

  def generate_properties_enum
    return "" if @properties.empty?
    arr = []
    @properties.each_with_index do |prop, i|
      name = prop[0]
      arr << "\t\tk#{name.capitalize}" + (i == 0 ? " = 1" : "")
    end
    str =  "\tenum {\n"
    str << arr.join(",\n") << "\n"
    str << "\t};\n"
  end

  def generate_properties_array
    arr = []
    @properties.each do |prop|
      name = prop[0]
      arr << "\t\t\t{\"#{name}\", k#{name.capitalize}, JSPROP_PERMANENT | JSPROP_SHARED, S_#{@name}::jsPropertyGet, S_#{@name}::jsPropertySet}"
    end
    # not needed!
    # @parents.each do |parent|
    #   only_names = @properties.map { |m| m[0] }
    #   real_class = @generator.classes[parent[:record_id]]
    #   if real_class[:generator].nil?
    #     real_class[:generator] = CppClass.new(real_class[:xml], @generator)
    #   end
    #   real_class[:generator].properties.each do |prop|
    #     name = prop[0]
    #     unless only_names.include?(name)
    #       arr << "\t\t\t{\"#{name}\", k#{name.capitalize}, JSPROP_PERMANENT | JSPROP_SHARED, S_#{parent[:name]}::jsPropertyGet, S_#{parent[:name]}::jsPropertySet}"
    #     end
    #   end
    # end
    arr << "\t\t\t{0, 0, 0, 0, 0}"
    str =  "\t\tstatic JSPropertySpec properties[] = {\n"
    str << arr.join(",\n") << "\n"
    str << "\t\t};\n"
  end

  def generate_funcs_array
    arr = []
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      # skip event methods (only called from C++) and static methods (also, skip update)
      next if name =~ /^on/ || name =~ /^ccTouch/ || m.static || name == "update"
      arr << "\t\t\tJS_FN(\"#{name}\", S_#{@name}::js#{name}, #{m.num_arguments}, JSPROP_PERMANENT | JSPROP_SHARED)"
    end
    # not needed!
    # @parents.each do |parent|
    #   only_names = @methods.map { |m| m[0] }
    #   real_class = @generator.classes[parent[:record_id]]
    #   if real_class[:generator].nil?
    #     real_class[:generator] = CppClass.new(real_class[:xml], @generator)
    #   end
    #   real_class[:generator].methods.each do |method|
    #     name = method[0]
    #     m = method[1].first
    #     next if name =~ /^on/ || name =~ /^ccTouch/ || m.static || name == "update"
    #     unless only_names.include?(name)
    #       arr << "\t\t\tJS_FN(\"#{name}\", S_#{parent[:name]}::js#{name}, #{m.num_arguments}, JSPROP_PERMANENT | JSPROP_SHARED)"
    #     end
    #   end
    # end

    arr << "\t\t\tJS_FS_END"
    str =  "\t\tstatic JSFunctionSpec funcs[] = {\n"
    str << arr.join(",\n") << "\n"
    str << "\t\t};\n\n"

    # static functions
    arr = []
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      next if !m.static
      arr << "\t\t\tJS_FN(\"#{name}\", S_#{@name}::js#{name}, #{m.num_arguments}, JSPROP_PERMANENT | JSPROP_SHARED)"
    end
    arr << "\t\t\tJS_FS_END"
    str << "\t\tstatic JSFunctionSpec st_funcs[] = {\n"
    str << arr.join(",\n") << "\n"
    str << "\t\t};\n"
  end

  def generate_funcs_declarations
    str = ""
    needs_update = false
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      needs_update = true if name =~ /^scheduleUpdate/
      if name =~ /^(on|ccTouch)/
        # override the instance method
        str << "\tvirtual #{m.native_signature};\n"
      else
        str << "\tstatic JSBool js#{name}(JSContext *cx, uint32_t argc, jsval *vp);\n"
      end
    end
    if needs_update || @parents.map{ |p| p[:name] }.include?("CCNode")
      str << "\tvirtual void update(ccTime delta);\n"
    end
    str
  end

  def generate_funcs
    str = ""
    needs_update = false
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      needs_update = true if name =~ /^scheduleUpdate/
      # event
      if name =~ /^(on|ccTouch)/
        # override the instance method
        touchBegan = name == "ccTouchBegan"
        str << "#{m.native_signature(true)} {\n"
        str << "\tif (m_jsobj) {\n"
        str << "\t\tJSContext* cx = ScriptingCore::getInstance().getGlobalContext();\n"
        str << "\t\tJSBool found; JS_HasProperty(cx, m_jsobj, \"#{name}\", &found);\n"
        str << "\t\tif (found == JS_TRUE) {\n"
        str << "\t\t\tjsval rval, fval;\n"
        str << "\t\t\tJS_GetProperty(cx, m_jsobj, \"#{name}\", &fval);\n"
        if name =~ /^on/
          str << "\t\t\tJS_CallFunctionValue(cx, m_jsobj, fval, 0, 0, &rval);\n"
        else
          # check if we're on a touch or touches: if it's touch, just pass a CCTouch, otherwise pass
          # and array of CCTouches
          if name =~ /ccTouches/
            str << "\t\t\tjsval *touches = new jsval[pTouches->count()];\n"
            str << "\t\t\tCCTouch *pTouch;\n"
            str << "\t\t\tCCSetIterator setIter;\n"
            str << "\t\t\tint i=0;\n"
            str << "\t\t\tfor (setIter = pTouches->begin(); setIter != pTouches->end(); setIter++, i++) {\n"
            str << "\t\t\t\tpTouch = (CCTouch *)(*setIter);\n"
            str << "\t\t\t\tCCPoint pt = pTouch->locationInView();\n"
            str << "\t\t\t\tCCTouch *touch = new CCTouch(pt.x, pt.y);\n"
            str << "\t\t\t\tpointerShell_t *shell = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
            str << "\t\t\t\tshell->flags = kPointerTemporary;\n"
            str << "\t\t\t\tshell->data = (void *)touch;\n"
            str << "\t\t\t\tJSObject *tmp = JS_NewObject(cx, S_CCTouch::jsClass, S_CCTouch::jsObject, NULL);\n"
            str << "\t\t\t\tJS_SetPrivate(tmp, shell);\n"
            str << "\t\t\t\ttouches[i] = OBJECT_TO_JSVAL(tmp);\n"
            str << "\t\t\t}\n"
            str << "\t\t\tJSObject *array = JS_NewArrayObject(cx, pTouches->count(), touches);\n"
            str << "\t\t\tjsval arg = OBJECT_TO_JSVAL(array);\n"
            str << "\t\t\tJS_CallFunctionValue(cx, m_jsobj, fval, 1, &arg, &rval);\n"
            str << "\t\t\tdelete touches;\n"
          else
            str << "\t\t\tpointerShell_t *shell = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
            str << "\t\t\tshell->flags = kPointerTemporary;\n"
            str << "\t\t\tshell->data = (void *)pTouch;\n"
            str << "\t\t\tJSObject *tmp = JS_NewObject(cx, S_CCTouch::jsClass, S_CCTouch::jsObject, NULL);\n"
            str << "\t\t\tJS_SetPrivate(tmp, shell);\n"
            str << "\t\t\tjsval arg = OBJECT_TO_JSVAL(tmp);\n"
            str << "\t\t\tJS_CallFunctionValue(cx, m_jsobj, fval, 1, &arg, &rval);\n"
          end
          if touchBegan
            str << "\t\t\tJSBool ret = false;\n"
            str << "\t\t\tJS_ValueToBoolean(cx, rval, &ret);\n"
            str << "\t\t\treturn ret;\n"
          end
        end
        str << "\t\t}\n"
        str << "\t}\n"
        str << "\treturn false;\n" if touchBegan
      else
        str << "JSBool S_#{@name}::js#{name}(JSContext *cx, uint32_t argc, jsval *vp) {\n"
        unless m.static
          str << "\tJSObject* obj = (JSObject *)JS_THIS_OBJECT(cx, vp);\n"
          str << "\tS_#{@name}* self = NULL; JSGET_PTRSHELL(S_#{@name}, self, obj);\n"
          str << "\tif (self == NULL) return JS_FALSE;\n"
        end
        m.convert_arguments_and_call(str, 1)
        str << "\tJS_SET_RVAL(cx, vp, JSVAL_TRUE);\n"
        str << "\treturn JS_TRUE;\n"
      end
      if name =~ /^on/
        str << "\t\t\t#{@name}::#{name}();\n"
      end
      str << "}\n"
    end
    # add "update" if needed
    if needs_update || @parents.map{ |p| p[:name] }.include?("CCNode")
      str << "void S_#{@name}::update(ccTime delta) {\n"
      str << "\tif (m_jsobj) {\n"
      str << "\t\tJSContext* cx = ScriptingCore::getInstance().getGlobalContext();\n"
      str << "\t\tJSBool found; JS_HasProperty(cx, m_jsobj, \"update\", &found);\n"
      str << "\t\tif (found == JS_TRUE) {\n"
      str << "\t\t\tjsval rval, fval;\n"
      str << "\t\t\tJS_GetProperty(cx, m_jsobj, \"update\", &fval);\n"
      str << "\t\t\tjsval jsdelta; JS_NewNumberValue(cx, delta, &jsdelta);\n"
      str << "\t\t\tJS_CallFunctionValue(cx, m_jsobj, fval, 1, &jsdelta, &rval);\n"
      str << "\t\t}\n"
      str << "\t}\n"
      str << "}\n"
    end
    str
  end

  def generate_constructor_code
    str =  ""
    if @singleton
      str << "JSBool S_#{@name}::jsConstructor(JSContext *cx, uint32_t argc, jsval *vp)\n"
      str << "{\n"
      str << "\treturn JS_FALSE;\n"
      str << "};\n"
    else
      str << "JSBool S_#{@name}::jsConstructor(JSContext *cx, uint32_t argc, jsval *vp)\n"
      str << "{\n"
      str << "\tJSObject *obj = JS_NewObject(cx, S_#{@name}::jsClass, S_#{@name}::jsObject, NULL);\n"
      str << "\tS_#{@name} *cobj = new S_#{@name}(obj);\n"
      str << "\tpointerShell_t *pt = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
      str << "\tpt->flags = 0; pt->data = cobj;\n"
      str << "\tJS_SetPrivate(obj, pt);\n"
      str << "\tJS_SET_RVAL(cx, vp, OBJECT_TO_JSVAL(obj));\n"
      str << "\treturn JS_TRUE;\n"
      str << "}\n"
    end
  end

  def generate_finalizer
    str =  ""
    str << "void S_#{@name}::jsFinalize(JSContext *cx, JSObject *obj)\n"
    str << "{\n"
    str << "\tpointerShell_t *pt = (pointerShell_t *)JS_GetPrivate(obj);\n"
    str << "\tif (pt) {\n"
    str << "\t\tif (!(pt->flags & kPointerTemporary) && pt->data) delete (S_#{@name} *)pt->data;\n"
    str << "\t\tJS_free(cx, pt);\n"
    str << "\t}\n"
    str << "}\n"
  end

  def generate_getter
    str =  ""
    str << "JSBool S_#{@name}::jsPropertyGet(JSContext *cx, JSObject *obj, jsid _id, jsval *val)\n"
    str << "{\n"
    str << "\tint32_t propId = JSID_TO_INT(_id);\n"
    str << "\tS_#{@name} *cobj; JSGET_PTRSHELL(S_#{@name}, cobj, obj);\n"
    str << "\tif (!cobj) return JS_FALSE;\n"
    str << "\tswitch(propId) {\n"
    # debugger if @name == "CCTouch"
    @properties.each do |prop, val|
      next if val[:requires_accessor] && val[:getter].nil?
      convert_code = convert_value_to_js(val, prop, "val", 2)
      next if convert_code.nil?
      str << "\tcase k#{prop.capitalize}:\n"
      str << "\t\t#{convert_code}\n"
      str << "\t\tbreak;\n"
    end
    str << "\tdefault:\n"
    str << "\t\tbreak;\n"
    str << "\t}\n"
    str << "\treturn JS_TRUE;\n"
    str << "}\n"
  end

  def generate_setter
    str =  ""
    str << "JSBool S_#{@name}::jsPropertySet(JSContext *cx, JSObject *obj, jsid _id, JSBool strict, jsval *val)\n"
    str << "{\n"
    str << "\tint32_t propId = JSID_TO_INT(_id);\n"
    str << "\tS_#{@name} *cobj; JSGET_PTRSHELL(S_#{@name}, cobj, obj);\n"
    str << "\tif (!cobj) return JS_FALSE;\n"
    str << "\tswitch(propId) {\n"
    @properties.each do |prop, val|
      next if val[:requires_accessor] && val[:setter].nil?
      convert_code = convert_value_from_js(val, "val", prop, 2)
      next if convert_code.nil?
      str << "\tcase k#{prop.capitalize}:\n"
      str << "\t\t#{convert_code}\n"
      str << "\t\tbreak;\n"
    end
    str << "\tdefault:\n"
    str << "\t\tbreak;\n"
    str << "\t}\n"
    str << "\treturn JS_TRUE;\n"
    str << "}\n"
  end

  def generate_declaration
    str =  ""
    str << "class S_#{@name} : public #{@name}\n"
    str << "{\n"
    str << "\tJSObject *m_jsobj;\n"
    str << "public:\n"
    str << "\tstatic JSClass *jsClass;\n"
    str << "\tstatic JSObject *jsObject;\n\n"
    str << "\tS_#{@name}(JSObject *obj) : #{@name}(), m_jsobj(obj) {};\n" unless @singleton
    str << generate_properties_enum << "\n"
    str << "\tstatic JSBool jsConstructor(JSContext *cx, uint32_t argc, jsval *vp);\n"
    str << "\tstatic void jsFinalize(JSContext *cx, JSObject *obj);\n"
    str << "\tstatic JSBool jsPropertyGet(JSContext *cx, JSObject *obj, jsid _id, jsval *val);\n"
    str << "\tstatic JSBool jsPropertySet(JSContext *cx, JSObject *obj, jsid _id, JSBool strict, jsval *val);\n"
    str << "\tstatic void jsCreateClass(JSContext *cx, JSObject *globalObj, const char *name);\n"
    str << generate_funcs_declarations << "\n"
    str << "};\n\n"
  end

  def generate_implementation
    str =  ""
    str << "JSClass* S_#{@name}::jsClass = NULL;\n"
    str << "JSObject* S_#{@name}::jsObject = NULL;\n\n"
    str << generate_constructor_code << "\n"
    str << generate_finalizer << "\n"
    str << generate_getter << "\n"
    str << generate_setter << "\n"
    # class registration +method+
    str << "void S_#{@name}::jsCreateClass(JSContext *cx, JSObject *globalObj, const char *name)\n"
    str << "{\n"
    str << "\tjsClass = (JSClass *)calloc(1, sizeof(JSClass));\n"
    str << "\tjsClass->name = name;\n"
    str << "\tjsClass->addProperty = JS_PropertyStub;\n"
    str << "\tjsClass->delProperty = JS_PropertyStub;\n"
    str << "\tjsClass->getProperty = JS_PropertyStub;\n"
    str << "\tjsClass->setProperty = JS_StrictPropertyStub;\n"
    str << "\tjsClass->enumerate = JS_EnumerateStub;\n"
    str << "\tjsClass->resolve = JS_ResolveStub;\n"
    str << "\tjsClass->convert = JS_ConvertStub;\n"
    str << "\tjsClass->finalize = jsFinalize;\n"
    str << "\tjsClass->flags = JSCLASS_HAS_PRIVATE;\n"
    str << generate_properties_array << "\n"
    str << generate_funcs_array << "\n"
    parent_proto = "NULL"
    unless @parents.empty?
      parent = @parents[0]
      parent_proto = "S_#{parent[:name]}::jsObject" unless parent[:name] == "CCObject"
    end
    str << "\tjsObject = JS_InitClass(cx,globalObj,#{parent_proto},jsClass,S_#{@name}::jsConstructor,0,properties,funcs,NULL,st_funcs);\n"
    str << "}\n\n"
    str << generate_funcs << "\n"
  end

  def to_s
    "Class: #{@name}"
  end

  # convert a JS object to C++
  def convert_value_from_js(val, invalue, outvalue, indent_level, outvalue_prefix = "cobj->")
    v = {:type => val[:type]}
    @generator.real_type(v)
    prop = v[:type]

    indent = "\t" * (indent_level || 0)
    str = ""
    type = {}
    # debugger if outvalue == "opacity"
    if @generator.find_type(prop, type)
      return nil if type[:name].nil?
      if type[:fundamental] && !type[:pointer]
        case type[:name]          
        when /float|double/
          if val[:requires_accessor] && val[:setter]
            set_str = "#{outvalue_prefix}#{val[:setter].name}(tmp)"
            str << "do { double tmp; JS_ValueToNumber(cx, *#{invalue}, &tmp); #{set_str}; } while (0);"
          else
            str << "do { double tmp; JS_ValueToNumber(cx, *#{invalue}, &tmp); #{outvalue_prefix}#{outvalue} = tmp; } while (0);"
          end
        when /int|long|short|char/
          if val[:requires_accessor] && val[:setter]
            set_str = "#{outvalue_prefix}#{val[:setter].name}(tmp)"
            str << "do { uint32_t tmp; JS_ValueToECMAUint32(cx, *#{invalue}, &tmp); #{set_str}; } while (0);"
          else
            str << "do { uint32_t tmp; JS_ValueToECMAUint32(cx, *#{invalue}, &tmp); #{outvalue_prefix}#{outvalue} = tmp; } while (0);"
          end
        when /bool|BOOL/
          if val[:requires_accessor] && val[:setter]
            set_str = "#{outvalue_prefix}#{val[:setter].name}(tmp)"
            str << "do { JSBool tmp; JS_ValueToBoolean(cx, *#{invalue}, &tmp); #{set_str}; } while (0);"
          else
            str << "do { JSBool tmp; JS_ValueToBoolean(cx, *#{invalue}, &tmp); #{outvalue_prefix}#{outvalue} = tmp; } while (0);"
          end
        end
      else
        set_str = outvalue_prefix
        setter = false
        if val[:requires_accessor]
          return nil if val[:setter].nil?
          set_str << "#{val[:setter].name}("
          setter = true
          setter_type = val[:setter].first_argument_type
        else
          set_str << outvalue
        end
        ref = false
        if type[:class] || type[:reference]
          ref = true unless setter && setter_type[:pointer]
        end
        str << "do {\n"
        # special case for char *
        if type[:fundamental] && type[:name] =~ /char/
          str << "#{indent}\tchar *tmp = JS_EncodeString(cx, *#{invalue});\n"
          ref = false
        else
          str << "#{indent}\t#{type[:name]}* tmp; JSGET_PTRSHELL(#{type[:name]}, tmp, JSVAL_TO_OBJECT(*#{invalue}));\n"
        end
        if setter
          set_str << "#{ref ? "*" : ""}tmp)"
        else
          set_str << " = #{ref ? "*" : ""}tmp"
        end
        str << "#{indent}\tif (tmp) { #{set_str}; }\n"
        str << "#{indent}} while (0);"
      end
    else
      str << "#{indent}// don't know what this is (js ~> c, #{prop})"
    end
    str
  end

  # convert a C++ object to JS
  def convert_value_to_js(val, invalue, outvalue, indent_level, inval_prefix = "cobj->")
    v = {:type => val[:type]}
    @generator.real_type(v)
    prop = v[:type]

    indent = "\t" * (indent_level || 0)
    str = ""
    type = {}
    # debugger if invalue == "opacity"
    if @generator.find_type(prop, type)
      return nil if type[:name].nil?
      inval_str = inval_prefix
      if val[:requires_accessor]
        return nil if val[:getter].nil? || !@generator.find_type(val[:getter].type, type)
        inval_str << "#{val[:getter].name}()"
      else
        inval_str << invalue
      end
      if type[:fundamental] && !val[:pointer]
        case type[:name]
        when /int|long|float|double|short|char/
          str << "do { jsval tmp; JS_NewNumberValue(cx, #{inval_str}, &tmp); JS_SET_RVAL(cx, #{outvalue}, tmp); } while (0);"
        when /bool/
          str << "JS_SET_RVAL(cx, #{outvalue}, BOOLEAN_TO_JSVAL(#{inval_str}));"
        end
      else
        ref = false
        if type[:class] || type[:reference]
          ref = true unless val[:pointer] || type[:pointer]
        end
        # debugger if @name == "CCNode" && inval_str == "ret"
        is_class = type[:class]
        js_class = (is_class) ? "S_#{type[:name]}::jsClass" : "NULL"
        js_proto = (is_class) ? "S_#{type[:name]}::jsObject" : "NULL"
        str << "do {\n"
        str << "#{indent}\tJSObject *tmp = JS_NewObject(cx, #{js_class}, #{js_proto}, NULL);\n"
        str << "#{indent}\tpointerShell_t *pt = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
        if ref
          # uses the copy constructor to get a new (in stack) object
          str << "#{indent}\t#{type[:name]}* ctmp = new #{type[:name]}(#{inval_str});\n"
          str << "#{indent}\tpt->flags = 0;\n"
          inval_str = "ctmp"
        else
          # just pass the reference, wrapped in a temporary object
          str << "#{indent}\tpt->flags = kPointerTemporary;\n"
        end
        str << "#{indent}\tpt->data = (void *)#{inval_str};\n"
        str << "#{indent}\tJS_SetPrivate(tmp, pt);\n"
        str << "#{indent}\tJS_SET_RVAL(cx, #{outvalue}, OBJECT_TO_JSVAL(tmp));\n"
        str << "#{indent}} while (0);"
      end
    else
      str << "#{indent}// don't know what this is (c ~> js, #{val.inspect})"
    end # if find_type
    str
  end
end

class BindingsGenerator
  attr_reader :classes, :fundamental_types, :pointer_types, :out_header, :out_impl
  CCRETAIN_METHODS = %w(
    addChild
    runAction
    runWithScene
    initWith*
  )

  # initialize everything with a nokogiri document
  def initialize(doc, out_prefix)
    out_prefix ||= "out"
    hfile_name = "#{out_prefix}.hpp"
    ifile_name = "#{out_prefix}.cpp"

    if File.exists?(hfile_name)
      FileUtils.copy(hfile_name, File.basename(hfile_name, ".hpp") + ".old.hpp")
    end
    if File.exists?(ifile_name)
      FileUtils.copy(ifile_name, File.basename(ifile_name, ".cpp") + ".old.cpp")
    end

    @out_header = File.open(hfile_name, "w+")
    @out_impl   = File.open(ifile_name, "w+")

    raise "Invalid XML file" if doc.root.name != "CLANG_XML"
    @translation_unit = (doc.root / "TranslationUnit").first rescue nil
    test_xml(@translation_unit && @translation_unit.name == "TranslationUnit")

    @reference_section = (doc.root / "ReferenceSection").first rescue nil
    test_xml(@reference_section && @reference_section.name == "ReferenceSection")

    @fundamental_types = {}
    @pointer_types = {}
    @reference_types = {}
    @classes = {}
    @const_volatile = {}
    @typedefs = {}

    @out_header.puts <<-EOS

#ifndef __#{out_prefix}__h
#define __#{out_prefix}__h

#include "ScriptingCore.h"
#include "cocos2d.h"

using namespace cocos2d;

typedef struct {
\tuint32_t flags;
\tvoid* data;
} pointerShell_t;

typedef enum {
\tkPointerTemporary = 1
} pointerShellFlags;

#define JSGET_PTRSHELL(type, cobj, jsobj) do { \\
\tpointerShell_t *pt = (pointerShell_t *)JS_GetPrivate(jsobj); \\
\tif (pt) { \\
\t\tcobj = (type *)pt->data; \\
\t} else { \\
\t\tcobj = NULL; \\
\t} \\
} while (0)

    EOS

    @out_impl.puts "#include \"#{out_prefix}.hpp\"\n\n"

    find_fundamental_types
    find_pointer_types
    find_references
    find_classes
    find_const_volatile_type
    find_typedefs
    # iterate over all collections finding incomplete dependencies
    # this is very expensive
    find_missing_dependencies
    instantiate_class_generators

    @out_header.puts "#endif\n\n"
    @out_header.close
    @out_impl.close
  end

  # returns a single character to append to the argument format string
  # @see https://developer.mozilla.org/en/SpiderMonkey/JSAPI_Reference/JS_ConvertArguments
  def arg_format(arg, type)
    real_type(arg)
    if find_type(arg[:type], type)
      if type[:fundamental]
        case type[:name]
        when /bool|BOOL/
          return "b"
        when /char/
          if type[:pointer]
            return "S"
          else
            return "c"
          end
        when /int|long|short/
          return "i"
        when /float|double/
          return "d"
        else
          return "*"
        end
      end
      return "o"
    else
      # $stderr.puts "no type for #{arg[:type]}"
      return "*"
    end
  end

  # searchs for a type, first on fundamental, then on references and finally
  # on classes. It also searches for a const-volatile type
  def find_type(type_id, result = {})
    ftype = @const_volatile[type_id]
    if ftype
      result[:const] = true
      return find_type(ftype[:type], result)
    end
    ftype = @fundamental_types[type_id]
    if ftype.nil?
      ftype = @pointer_types[type_id]
      if ftype
        result[:pointer] = true
        result[:name] = ftype[:name]
        result[:class] = true if ftype[:kind] == :class
        result[:fundamental] = true if ftype[:kind] == :fundamental
        return true
      end
      ftype = @classes[type_id]
      if ftype
        result[:name] = ftype[:name]
        result[:class] = true
        return true
      end
      ftype = @reference_types[type_id]
      if ftype
        result[:name] = ftype[:name]
        result[:reference] = true
        return true
      end
    else
      result[:name] = ftype
      result[:fundamental] = true
      return true
    end
    result[:name] = "INVALID"
    return false
  end

  # search for the real type
  def real_type(v)
    td = @typedefs[v[:type]]
    if td
      v[:type] = td[:type]
      v[:name] = td[:name]
      # search for recursive typedef
      real_type(v)
    end
  end

private
  def test_xml(cond)
    raise "invalid XML file" if !cond
  end

  def find_fundamental_types
    (@reference_section / "FundamentalType").each do |ft|
      @fundamental_types[ft['id']] = ft['kind']
    end
  end

  def find_pointer_types
    (@reference_section / "PointerType").each do |pt|
      ft = @fundamental_types[pt['type']]
      if ft
        @pointer_types[pt['id']] = {:type => pt['type'], :name => ft, :kind => :fundamental}
      else
        # will be filled later
        @pointer_types[pt['id']] = {:type => pt['type']}
      end
    end
  end

  def find_references
    (@reference_section / "ReferenceType").each do |ref|
      @reference_types[ref['id']] = {:type => ref['type']}
    end
  end

  def find_classes
    (@reference_section / "Record[@kind=class]").each do |record|
      # find the record on the translation unit and create the class
      (@translation_unit / "*/CXXRecord[@type=#{record['id']}]").each do |cxx_record|
        if cxx_record['forward'].nil?
          # just store the xml, we will instantiate them later
          # $stderr.puts "found class #{record['name']} - #{record['id']}"
          @classes[record['id']] = {:name => record['name'], :kind => :class, :xml => cxx_record, :record_id => record['id']}
          break
        end
      end # each CXXRecord
    end # each Record(class)
    (@reference_section / "Record[@kind=struct]").each do |record|
      # find the record on the translation unit and create the class
      (@translation_unit / "*/CXXRecord[@type=#{record['id']}]").each do |cxx_record|
        if cxx_record['forward'].nil?
          # just store the xml, we will instantiate them later
          # $stderr.puts "found class #{record['name']} - #{record['id']}"
          @classes[record['id']] = {:name => record['name'], :kind => :class, :xml => cxx_record, :record_id => record['id']}
          break
        end
      end # each CXXRecord
    end # each Record(struct)
  end

  def find_const_volatile_type
    (@reference_section / "*/CvQualifiedType").each do |cv|
      if cv['const'] == "1"
        @const_volatile[cv['id']] = {:type => cv['type']}
      end
    end
  end

  def find_typedefs
    (@reference_section / "*/Typedef").each do |td|
      # $stderr.puts "typedef from #{td['id']} -> #{td['type']}"
      @typedefs[td['id']] = {:name => td['name'], :type => td['type']}
    end
  end

  # iterate over references, pointers and const volatile to see if we have
  # missing dependencies (i.e. a pointer to a const, a const pointer, etc)
  def find_missing_dependencies
    # class pointer 
    @pointer_types.select { |k, v| v[:kind].nil? }.each do |k, v|
      real_type(v)
      klass = @classes[v[:type]]
      unless klass.nil?
        v[:name] = klass[:name]
        v[:kind] = :class
        next
      end
      cv = @const_volatile[v[:type]]
      unless cv.nil?
        cv[:deps] ||= []
        cv[:deps] << v
        next
      end
      ref = @reference_types[v[:type]]
      unless ref.nil?
        ref[:deps] ||= []
        ref[:deps] << v
      end
    end
    # const pointer
    @const_volatile.each do |k, v|
      real_type(v)
      fund = @fundamental_types[v[:type]]
      if fund
        v[:kind] = :fundamental
        v[:name] = fund
        complete_deps(v)
        next
      end
      ptr = @pointer_types[v[:type]]
      unless ptr.nil?
        v[:kind] = :pointer
        v[:name] = ptr[:name]
        complete_deps(v)
        next
      end
      # might be a class?
      klass = @classes[v[:type]]
      unless klass.nil?
        v[:kind] = :class
        v[:name] = klass[:name]
        complete_deps(v)
      else
        # $stderr.puts "unknown cv for type #{v[:type]}"
      end
    end
    # references
    @reference_types.each do |k, v|
      real_type(v)
      # fundamental
      fund = @fundamental_types[v[:type]]
      unless fund.nil?
        v[:kind] = :fundamental
        v[:name] = fund
        complete_deps(v)
        next
      end
      # find refs to classes
      klass = @classes[v[:type]]
      unless klass.nil?
        v[:kind] = :class
        v[:name] = klass[:name]
        complete_deps(v)
        next
      end
      # try with const volatile
      cv = @const_volatile[v[:type]]
      unless cv.nil?
        v[:kind] = cv[:kind]
        v[:name] = cv[:name]
        complete_deps(v)
      else
        # $stderr.puts "unknown reference for type #{v[:type]}"
      end
    end
  end

  def instantiate_class_generators
    green_lighted = %w(CCPoint CCSize CCRect CCDirector CCNode CCSprite CCScene CCSpriteFrameCache
                       CCSpriteFrame CCAction CCAnimate CCAnimation CCRepeatForever CCLayer CCTouch
                       CCSet CCMoveBy CCMoveTo CCRotateTo CCRotateBy CCRenderTexture CCMenu CCMenuItem
                       CCMenuItemLabel CCMenuItemSprite CCMenuItemImage CCLabelTTF CCSequence)
    # @classes.each { |k,v| puts v[:xml]['name'] unless green_lighted.include?(v[:xml]['name']) || v[:xml]['name'] !~ /^CC/ }
    @classes.select { |k,v| green_lighted.include?(v[:name]) }.each do |k,v|
      # do not always create the generator, it might have already being created
      # by a subclass
      v[:generator] ||= CppClass.new(v[:xml], self)
      @out_header.puts v[:generator].generate_declaration
      @out_impl.puts   v[:generator].generate_implementation
    end

    # output which ones are not greenlighted
  end

  def complete_deps(v)
    while dep = v[:deps].pop
      dep[:kind] = v[:kind]
      dep[:name] = v[:name]
    end if v[:deps]
  end

end

doc = Nokogiri::XML(File.read(ARGV[0]))
BindingsGenerator.new(doc, ARGV[1])
