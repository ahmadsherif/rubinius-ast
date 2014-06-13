# -*- encoding: us-ascii -*-

module CodeTools
  module AST
    class Alias < Node
      attr_accessor :to, :from

      def initialize(line, to, from)
        @line = line
        @to = to
        @from = from
      end

      def bytecode(g)
        pos(g)

        g.push_scope
        @to.bytecode(g)
        @from.bytecode(g)
        g.send :alias_method, 2, true
      end

      def to_sexp
        [:alias, @to.to_sexp, @from.to_sexp]
      end
    end

    class VAlias < Alias
      def bytecode(g)
        pos(g)

        g.push_rubinius
        g.find_const :Globals
        g.push_literal @from
        g.push_literal @to
        # TODO: fix #add_alias arg order to match #alias_method
        g.send :add_alias, 2
      end

      def to_sexp
        [:valias, @to, @from]
      end
    end

    class Undef < Node
      attr_accessor :name

      def initialize(line, sym)
        @line = line
        @name = sym
      end

      def bytecode(g)
        pos(g)

        g.push_scope
        @name.bytecode(g)
        g.send :__undef_method__, 1
      end

      def to_sexp
        [:undef, @name.to_sexp]
      end
    end

    # Is it weird that Block has the :arguments attribute? Yes. Is it weird
    # that MRI parse tree puts arguments and block_arg in Block? Yes. So we
    # make do and pull them out here rather than having something else reach
    # inside of Block.
    class Block < Node
      attr_accessor :array, :locals

      def initialize(line, array)
        @line = line
        @array = array

        # These are any local variable that are declared as explicit
        # locals for this scope. This is only used by the |a;b| syntax.
        @locals = nil
      end

      def extract_arguments
        if @array.first.kind_of? Parameters
          node = @array.shift
          if @array.first.kind_of? BlockArgument
            node.block_arg = @array.shift
          end
          return node
        end
      end

      def bytecode(g)
        count = @array.size - 1
        @array.each_with_index do |x, i|
          start_ip = g.ip
          x.bytecode(g)
          g.pop unless start_ip == g.ip or i == count
        end
      end

      def to_sexp
        @array.inject([:block]) { |s, x| s << x.to_sexp }
      end
    end

    class ClosedScope < Node
      include Compiler::LocalVariables

      attr_accessor :body

      # A nested scope is looking up a local variable. If the variable exists
      # in our local variables hash, return a nested reference to it.
      def search_local(name)
        if variable = variables[name]
          variable.nested_reference
        end
      end

      def new_local(name)
        variables[name] ||= Compiler::LocalVariable.new allocate_slot
      end

      def new_nested_local(name)
        new_local(name).nested_reference
      end

      # There is no place above us that may contain a local variable. Set the
      # local in our local variables hash if not set. Set the local variable
      # node attribute to a reference to the local variable.
      def assign_local_reference(var)
        unless variable = variables[var.name]
          variable = new_local var.name
        end

        var.variable = variable.reference
      end

      def nest_scope(scope)
        scope.parent = self
      end

      def module?
        false
      end

      def attach_and_call(g, arg_name, scoped=false, pass_block=false)
        name = @name || arg_name
        meth = new_generator(g, name)

        meth.push_state self
        meth.for_module_body = true

        if scoped
          meth.push_self
          meth.add_scope
        end

        meth.state.push_name name

        @body.bytecode meth

        meth.state.pop_name

        meth.ret
        meth.close

        meth.local_count = local_count
        meth.local_names = local_names

        meth.pop_state

        g.create_block meth
        g.swap
        g.push_scope
        g.push_true
        g.send :call_under, 3

        return meth
      end

      def to_sexp
        sexp = [:scope]
        sexp << @body.to_sexp if @body
        sexp
      end
    end

    class Define < ClosedScope
      attr_accessor :name, :arguments

      def initialize(line, name, block)
        @line = line
        @name = name
        @arguments = block.extract_arguments
        block.array << NilLiteral.new(line) if block.array.empty?
        @body = block
      end

      def compile_body(g)
        meth = new_generator(g, @name, @arguments)

        meth.push_state self
        meth.state.push_super self
        meth.definition_line(@line)

        meth.state.push_name @name

        @arguments.bytecode(meth)
        @body.bytecode(meth)

        meth.state.pop_name

        meth.local_count = local_count
        meth.local_names = local_names

        meth.ret
        meth.close
        meth.pop_state

        return meth
      end

      def bytecode(g)
        pos(g)

        g.push_rubinius
        g.push_literal @name
        g.push_generator compile_body(g)
        g.push_scope
        g.push_variables
        g.send :method_visibility, 0

        g.send :add_defn_method, 4
      end

      def to_sexp
        [:defn, @name, @arguments.to_sexp, [:scope, @body.to_sexp]]
      end
    end

    class DefineSingleton < Node
      attr_accessor :receiver, :body

      def initialize(line, receiver, name, block)
        @line = line
        @receiver = receiver
        @body = DefineSingletonScope.new line, name, block
      end

      def bytecode(g)
        pos(g)

        @body.bytecode(g, @receiver)
      end

      def to_sexp
        [:defs, @receiver.to_sexp, @body.name,
          @body.arguments.to_sexp, [:scope, @body.body.to_sexp]]
      end
    end

    class DefineSingletonScope < Define
      def initialize(line, name, block)
        super line, name, block
      end

      def bytecode(g, recv)
        pos(g)

        g.push_rubinius
        g.push_literal @name
        g.push_generator compile_body(g)
        g.push_scope
        recv.bytecode(g)

        g.send :attach_method, 4
      end
    end

    class Lambda < Node
      attr_accessor :arguments, :body

      def initialize(line, arguments, body)
        @line = line
        @arguments = arguments
        @body = Iter.new line, arguments, body
      end

      def bytecode(g)
        pos(g)

        g.push_rubinius
        @body.bytecode(g)
        g.send_with_block :lambda, 0, false
      end

      def to_sexp
        [:lambda, @arguments.to_sexp, [:scope, @body.body.to_sexp]]
      end
    end

    class Parameters < Node
      attr_accessor :names, :required, :optional, :defaults, :splat,
                    :post, :keywords, :kwrest
      attr_reader :block_arg, :block_index

      def initialize(line, required, optional, splat, post, kwargs, kwrest, block)
        @line = line
        @defaults = nil
        @keywords = nil
        @block_arg = nil
        @splat_index = nil
        @block_index = nil
        @locals = []
        @local_index = 0

        names = []

        process_fixed_arguments required, @required = [], names

        if optional
          @defaults = DefaultArguments.new line, optional
          @optional = @defaults.names
          names.concat @optional
          @locals.concat @defaults.arguments
        else
          @optional = []
        end

        case splat
        when Symbol
          names << splat
          @locals << splat
        when true
          splat = :*
          names << splat
          @locals << local_placeholder
        when false
          splat = :*
          @locals << local_placeholder
          # @splat_index = -3
          # splat = nil
        end

        @splat = splat

        process_fixed_arguments post, @post = [], names

        if kwargs
          @keywords = KeywordParameters.new line, kwargs, kwrest
          names.concat @keywords.names
        elsif kwrest
          @keywords = KeywordParameters.new line, nil, kwrest
        end

        if @keywords
          var = local_placeholder
          @keywords.value = LocalVariableAccess.new line, var
          @locals << var
        end

        @names = names

        self.block_arg = block
      end

      def process_fixed_arguments(array, arguments, names)
        if array
          array.each do |arg|
            case arg
            when Symbol
              var = local_name arg
              names << var
            when MultipleAssignment
              var = arg
              var.right = LocalVariableAccess.new line, local_placeholder
              # @required << PatternArguments.from_masgn(arg)
              # @splat_index = -4 if @required.size == 1
            end

            arguments << var
            @locals << var
          end
        end
      end

      def local_name(argument)
        local_placeholder if argument == :_ and @local_index > 0
        argument
      end

      def local_placeholder
        :"_:#{@local_index += 1}"
      end

      def block_arg=(block)
        case block
        when BlockArgument
          @block_arg = block
        when nil
          return
        else
          @block_arg = BlockArgument.new @line, block
        end

        if @locals.last.kind_of? BlockArgument
          @block_index -= 1
          @locals.pop
        end
        @names.pop if @names.last.kind_of? BlockArgument

        @block_index = @locals.size
        @locals << @block_arg
        @names << @block_arg.name
      end

      def required_args
        @required.size + @post.size
      end

      def post_args
        @post.size
      end

      def total_args
        @required.size + @optional.size + @post.size
      end

      def splat_index
        return @required.size + @optional.size if @splat

        # return @splat_index if @splat_index

        # if @splat
        #   index = @names.size
        #   index -= 1 if @block_arg
        #   index -= 1 if @splat.kind_of? Symbol
        #   index -= @post.size
        #   index
        # end
      end

      def arity
        arity = required_args

        if @keywords and @keywords.required?
          arity += 1
        end

        if @splat or not @optional.empty? or
            (@keywords and not @keywords.required?)
          arity += 1
        end

        if @splat or not @optional.empty? or
            (@keywords and not @keywords.required?)
          arity = -arity
        end

        arity
      end

      def map_arguments(scope)
        @locals.map do |v|
          case v
          when Symbol
            scope.new_local v
          when MultipleAssignment
            scope.assign_local_reference v.right
          else
            scope.assign_local_reference v
          end
        end

        @keywords.map_arguments(scope) if @keywords

        # @required.each do |arg|
        #   case arg
        #   when MultipleAssignment
        #     arg.map_arguments scope
        #   when Symbol
        #     scope.new_local arg
        #   end
        # end

        # @defaults.map_arguments scope if @defaults
        # scope.new_local @splat if @splat.kind_of? Symbol

        # @post.each do |arg|
        #   case arg
        #   when PatternArguments
        #     arg.map_arguments scope
        #   when Symbol
        #     scope.new_local arg
        #   end
        # end

        # scope.assign_local_reference @block_arg if @block_arg
      end

      def bytecode(g)
        g.state.check_for_locals = false
        map_arguments g.state.scope

        @required.each_with_index do |arg, index|
          # if arg.kind_of? PatternArguments
          if arg.kind_of? MultipleAssignment
            g.push_local index
            # arg.argument.position_bytecode(g)
            arg.bytecode(g)
            g.pop
          end
        end

        @defaults.bytecode(g) if @defaults

        index = @required.size + @optional.size
        index += 1 if @splat_index

        @post.each do |arg|
          # if arg.kind_of? PatternArguments
          if arg.kind_of? MultipleAssignment
            # arg.argument.position_bytecode(g)
            g.push_local index
            index += 1
            arg.bytecode(g)
            g.pop
          end
        end

        @keywords.bytecode(g) if @keywords

        @block_arg.bytecode(g) if @block_arg

        g.state.check_for_locals = true
      end

      def to_sexp
        sexp = [:args]

        @required.each do |a|
          case a
          when Symbol
            sexp << a
          when Node
            sexp << a.to_sexp
          end
        end

        sexp += @defaults.names if @defaults

        if @splat == :*
          sexp << :*
        elsif @splat
          sexp << :"*#{@splat}"
        end

        if @post
          @post.each do |a|
            case a
            when Symbol
              sexp << a
            when Node
              sexp << a.to_sexp
            end
          end
        end

        sexp += @keywords.names if @keywords

        sexp << :"&#{@block_arg.name}" if @block_arg

        sexp << [:block] + @defaults.to_sexp if @defaults
        sexp << @keywords.to_sexp if @keywords

        sexp
      end
    end

    class PatternArguments < Node
      attr_accessor :arguments, :argument

      def self.from_masgn(node)
        array = []
        size = 0
        if node.left
          size += node.left.body.size
          node.left.body.map do |n|
            case n
            when MultipleAssignment
              array << PatternArguments.from_masgn(n)
            when LocalVariable
              array << LeftPatternVariable.new(n.line, n.name)
            end
          end
        end

        if node.splat
          s = node.splat
          case s
          when EmptySplat
            array << SplatPatternVariable.new(s.line, :*)
          when SplatAssignment, SplatWrapped, SplatArray
            array << SplatPatternVariable.new(s.value.line, s.value.name)
          end
        end

        if node.post
          idx = 0
          node.post.body.map do |n|
            case n
            when MultipleAssignment
              array << PatternArguments.from_masgn(n)
            when LocalVariable
              array << PostPatternVariable.new(n.line, n.name, idx)
            end
            idx += 1
          end
        end

        PatternArguments.new node.line, ArrayLiteral.new(node.line, array)
      end

      def initialize(line, arguments)
        @line = line
        @arguments = arguments
        @argument = nil
      end

      # Assign the left-most, depth-first PatternVariable so that this local
      # will be assigned the passed argument at that position. The rest of the
      # pattern will be destructured from the value of this assignment.
      def map_arguments(scope)
        arguments = @arguments.body
        while arguments
          node = arguments.first
          case node
          when LeftPatternVariable, PostPatternVariable, SplatPatternVariable
            @argument = node
            scope.new_local node.name
            scope.assign_local_reference node
            return
          end
          arguments = node.arguments.body
        end
      end

      def bytecode(g)
        @arguments.body.each do |arg|
          if arg.kind_of? PatternArguments
            g.shift_array
            g.cast_array
            arg.bytecode(g)
            g.pop
          else
            arg.bytecode(g)
          end
        end
      end

      def to_sexp
        [:masgn, @arguments.to_sexp]
      end
    end

    class DefaultArguments < Node
      attr_accessor :arguments, :names

      def initialize(line, block)
        @line = line
        array = block.array
        @names = array.map { |a| a.name }
        @arguments = array
      end

      def map_arguments(scope)
        @arguments.each { |var| scope.assign_local_reference var }
      end

      def bytecode(g)
        @arguments.each do |arg|
          done = g.new_label

          g.passed_arg arg.variable.slot
          g.git done
          arg.bytecode(g)
          g.pop

          done.set!
        end
      end

      def to_sexp
        @arguments.map { |x| x.to_sexp }
      end
    end

    class KeywordParameters < Node
      attr_accessor :arguments, :defaults, :names, :kwrest, :value

      def initialize(line, block, kwrest)
        @line = line
        @kwrest = kwrest

        if block
          array = block.array
          @names = array.map { |a| a.name }
          @defaults = array.reject do |a|
            a.value.kind_of? SymbolLiteral and a.value.value == :*
          end
          @arguments = array
        else
          @names = []
          @defaults = []
          @arguments = []
        end

        case kwrest
        when Symbol
          @kwrest = :"**#{kwrest}"
        when true
          @kwrest = :**
        end

        @names << @kwrest if @kwrest
      end

      def required?
        @defaults.size < @arguments.size
      end

      def entries
        entries = []

        @arguments.map do |a|
          required = a.value.kind_of?(SymbolLiteral) && a.value.value == :*

          entries << a.name
          entries << required
        end

        entries
      end

      def map_arguments(scope)
        @arguments.each { |var| scope.assign_local_reference var }
      end

      def bytecode(g)
        @defaults.each do |arg|
          done = g.new_label

          g.push_local arg.variable.slot
          g.push_undef
          g.send :equal?, 1, false
          g.git done
          arg.bytecode(g)
          g.pop

          done.set!
        end
      end

      def to_sexp
        sexp = [:block]
        sexp << @names unless @names.empty?
        sexp << @defaults.map { |x| x.to_sexp } unless @defaults.empty?
        sexp
      end
    end

    module LocalVariable
      attr_accessor :variable
    end

    class BlockArgument < Node
      include LocalVariable

      attr_accessor :name

      def initialize(line, name)
        @line = line
        @name = name
      end

      def bytecode(g)
        pos(g)

        g.push_proc

        if @variable.respond_to?(:depth) && @variable.depth != 0
          g.set_local_depth @variable.depth, @variable.slot
        else
          g.set_local @variable.slot
        end

        g.pop
      end
    end

    class Class < Node
      attr_accessor :name, :superclass, :body

      def initialize(line, name, superclass, body)
        @line = line

        @superclass = superclass ? superclass : NilLiteral.new(line)

        case name
        when Symbol
          @name = ClassName.new line, name, @superclass
        when ToplevelConstant
          @name = ToplevelClassName.new line, name, @superclass
        else
          @name = ScopedClassName.new line, name, @superclass
        end

        if body
          @body = ClassScope.new line, @name, body
        else
          @body = EmptyBody.new line
        end
      end

      def bytecode(g)
        @name.bytecode(g)
        @body.bytecode(g)
      end

      def to_sexp
        superclass = @superclass.kind_of?(NilLiteral) ? nil : @superclass.to_sexp
        [:class, @name.to_sexp, superclass, @body.to_sexp]
      end
    end

    class ClassScope < ClosedScope
      def initialize(line, name, body)
        @line = line
        @name = name.name
        @body = body
      end

      def module?
        true
      end

      def bytecode(g)
        pos(g)

        attach_and_call g, :__class_init__, true
      end
    end

    class ClassName < Node
      attr_accessor :name, :superclass

      def initialize(line, name, superclass)
        @line = line
        @name = name
        @superclass = superclass
      end

      def name_bytecode(g)
        g.push_rubinius
        g.push_literal @name
        @superclass.bytecode(g)
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        g.push_scope
        g.send :open_class, 3
      end

      def to_sexp
        @name
      end
    end

    class ToplevelClassName < ClassName
      def initialize(line, node, superclass)
        @line = line
        @name = node.name
        @superclass = superclass
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        g.push_cpath_top
        g.send :open_class_under, 3
      end

      def to_sexp
        [:colon3, @name]
      end
    end

    class ScopedClassName < ClassName
      attr_accessor :parent

      def initialize(line, node, superclass)
        @line = line
        @name = node.name
        @parent = node.parent
        @superclass = superclass
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        @parent.bytecode(g)
        g.send :open_class_under, 3
      end

      def to_sexp
        [:colon2, @parent.to_sexp, @name]
      end
    end

    class Module < Node
      attr_accessor :name, :body

      def initialize(line, name, body)
        @line = line

        case name
        when Symbol
          @name = ModuleName.new line, name
        when ToplevelConstant
          @name = ToplevelModuleName.new line, name
        else
          @name = ScopedModuleName.new line, name
        end

        if body
          @body = ModuleScope.new line, @name, body
        else
          @body = EmptyBody.new line
        end
      end

      def bytecode(g)
        @name.bytecode(g)
        @body.bytecode(g)
      end

      def to_sexp
        [:module, @name.to_sexp, @body.to_sexp]
      end
    end

    class EmptyBody < Node
      def bytecode(g)
        g.pop
        g.push :nil
      end

      def to_sexp
        [:scope]
      end
    end

    class ModuleName < Node
      attr_accessor :name

      def initialize(line, name)
        @line = line
        @name = name
      end

      def name_bytecode(g)
        g.push_rubinius
        g.push_literal @name
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        g.push_scope
        g.send :open_module, 2
      end

      def to_sexp
        @name
      end
    end

    class ToplevelModuleName < ModuleName
      def initialize(line, node)
        @line = line
        @name = node.name
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        g.push_cpath_top
        g.send :open_module_under, 2
      end

      def to_sexp
        [:colon3, @name]
      end
    end

    class ScopedModuleName < ModuleName
      attr_accessor :parent

      def initialize(line, node)
        @line = line
        @name = node.name
        @parent = node.parent
      end

      def bytecode(g)
        pos(g)

        name_bytecode(g)
        @parent.bytecode(g)
        g.send :open_module_under, 2
      end

      def to_sexp
        [:colon2, @parent.to_sexp, @name]
      end
    end

    class ModuleScope < ClosedScope
      def initialize(line, name, body)
        @line = line
        @name = name.name
        @body = body
      end

      def module?
        true
      end

      def bytecode(g)
        pos(g)

        attach_and_call g, :__module_init__, true
      end
    end

    class SClass < Node
      attr_accessor :receiver

      def initialize(line, receiver, body)
        @line = line
        @receiver = receiver
        @body = SClassScope.new line, body
      end

      def bytecode(g)
        pos(g)
        @receiver.bytecode(g)
        @body.bytecode(g)
      end

      def to_sexp
        [:sclass, @receiver.to_sexp, @body.to_sexp]
      end
    end

    class SClassScope < ClosedScope
      def initialize(line, body)
        @line = line
        @body = body
        @name = nil
      end

      def bytecode(g)
        pos(g)

        g.push_type
        g.swap
        g.send :object_singleton_class, 1

        if @body
          # if @body just returns self, don't bother with it.
          if @body.kind_of? Block
            ary = @body.array
            return if ary.size == 1 and ary[0].kind_of? Self
          end

          # Ok, emit it.
          attach_and_call g, :__metaclass_init__, true, true
        else
          g.pop
          g.push :nil
        end
      end
    end

    class Container < ClosedScope
      attr_accessor :file, :name, :variable_scope, :pre_exe

      def initialize(body)
        @body = body || NilLiteral.new(1)
        @pre_exe = []
      end

      def push_state(g)
        g.push_state self
      end

      def pop_state(g)
        g.pop_state
      end

      def container_bytecode(g)
        g.name = @name
        g.file = @file.to_sym

        push_state(g)
        @pre_exe.each { |pe| pe.pre_bytecode(g) }

        yield if block_given?
        pop_state(g)

        g.local_count = local_count
        g.local_names = local_names
      end

      def to_sexp
        sexp = [sexp_name]
        @pre_exe.each { |pe| sexp << pe.pre_sexp }
        sexp << @body.to_sexp
        sexp
      end
    end

    class EvalExpression < Container
      def initialize(body)
        super body
        @name = :__eval_script__
      end

      def should_cache?
        !@body.kind_of?(AST::ClosedScope)
      end

      def search_scopes(name)
        depth = 1
        scope = @variable_scope
        while scope
          if !scope.method.for_eval? and slot = scope.method.local_slot(name)
            return Compiler::NestedLocalVariable.new(depth, slot)
          elsif scope.eval_local_defined?(name, false)
            return Compiler::EvalLocalVariable.new(name)
          end

          depth += 1
          scope = scope.parent
        end
      end

      # Returns a cached reference to a variable or searches all
      # surrounding scopes for a variable. If no variable is found,
      # it returns nil and a nested scope will create the variable
      # in itself.
      def search_local(name)
        if variable = variables[name]
          return variable.nested_reference
        end

        if variable = search_scopes(name)
          variables[name] = variable
          return variable.nested_reference
        end
      end

      def new_local(name)
        variables[name] ||= Compiler::EvalLocalVariable.new name
      end

      def assign_local_reference(var)
        unless reference = search_local(var.name)
          variable = new_local var.name
          reference = variable.reference
        end

        var.variable = reference
      end

      def push_state(g)
        g.push_state self
        g.state.push_eval self
      end

      def bytecode(g)
        super(g)

        container_bytecode(g) do
          @body.bytecode(g)
          g.ret
        end
      end

      def sexp_name
        :eval
      end
    end

    class Snippet < Container
      def initialize(body)
        super body
        @name = :__snippet__
      end

      def bytecode(g)
        super(g)

        container_bytecode(g) do
          @body.bytecode(g)
        end
      end

      def sexp_name
        :snippet
      end
    end

    class Script < Container
      def initialize(body)
        super body
        @name = :__script__
      end

      def bytecode(g)
        super(g)

        container_bytecode(g) do
          @body.bytecode(g)
          g.pop
          g.push :true
          g.ret
        end
      end

      def sexp_name
        :script
      end
    end

    class Defined < Node
      attr_accessor :expression

      def initialize(line, expr)
        @line = line
        @expression = expr
      end

      def bytecode(g)
        pos(g)

        @expression.defined(g)
      end

      def to_sexp
        [:defined, @expression.to_sexp]
      end
    end
  end
end
