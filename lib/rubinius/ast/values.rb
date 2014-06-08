# -*- encoding: us-ascii -*-

module CodeTools
  module AST
    class SplatValue < Node
      attr_accessor :value

      def initialize(line, value)
        @line = line
        @value = value
      end

      def bytecode(g)
        done = g.new_label

        @value.bytecode(g)
        kind_of_array(g, done)

        coerce = g.new_label

        g.dup
        g.push_literal :to_a
        g.send :respond_to?, 1, true
        g.git coerce

        g.make_array 1
        g.goto done

        coerce.set!
        g.dup
        g.send :to_a, 0, true

        discard = g.new_label
        kind_of_array(g, discard)

        g.push_type
        g.move_down 2
        g.push_literal :to_a
        g.push_cpath_top
        g.find_const :Array
        g.send :coerce_to_type_error, 4, true
        g.goto done

        discard.set!
        g.swap
        g.pop

        done.set!
      end

      def kind_of_array(g, label)
        g.dup
        g.push_cpath_top
        g.find_const :Array
        g.swap
        g.kind_of
        g.git label
      end

      def to_sexp
        [:splat, @value.to_sexp]
      end

      def splat?
        true
      end
    end

    class ConcatArgs < Node
      attr_accessor :array, :rest

      def initialize(line, array, rest)
        @line = line
        @array = array
        @rest = rest
      end

      def bytecode(g)
        if @array
          @array.bytecode(g)
          @rest.bytecode(g)
          g.cast_array
          g.send :+, 1
        else
          @rest.bytecode(g)
          g.cast_array
        end
      end

      # Dive down and try to find an array of regular values
      # that could construct the left side of a concatination.
      # This is used to minimize the splat doing a send.
      def peel_lhs
        case @array
        when ConcatArgs
          @array.peel_lhs
        when ArrayLiteral
          ary = @array.body
          @array = nil
          ary
        else
          nil
        end
      end

      def to_sexp
        [:argscat, @array.to_sexp, @rest.to_sexp]
      end

      def splat?
        true
      end
    end

    class PushArgs < Node
      attr_accessor :arguments, :value

      def initialize(line, arguments, value)
        @line = line
        @arguments = arguments
        @value = value
      end

      def bytecode(g)
        @arguments.bytecode(g)
        @value.bytecode(g)
        g.make_array 1
        g.send :+, 1
      end

      def to_sexp
        [:argspush, @arguments.to_sexp, @value.to_sexp]
      end

      def size
        1
      end

      def splat?
        @arguments.splat?
      end
    end


    class SValue < Node
      attr_accessor :value

      def initialize(line, value)
        @line = line
        @value = value
      end

      def bytecode(g)
        @value.bytecode(g)
        if @value.kind_of? SplatValue
          done = g.new_label

          g.dup
          g.send :size, 0
          g.push 1
          g.send :>, 1
          g.git done

          g.push 0
          g.send :at, 1

          done.set!
        end
      end

      def to_sexp
        [:svalue, @value.to_sexp]
      end
    end

    class ToArray < Node
      attr_accessor :value

      def initialize(line, value)
        @line = line
        @value = value
      end

      def bytecode(g)
        pos(g)

        @value.bytecode(g)
        g.cast_multi_value
      end

      def to_sexp
        [:to_ary, @value.to_sexp]
      end
    end

    class ToString < Node
      attr_accessor :value

      def initialize(line, value)
        @line = line
        @value = value
      end

      def bytecode(g)
        pos(g)

        @value.bytecode(g)
        g.meta_to_s
      end

      def value_defined(g, f)
        if @value
          @value.value_defined(g, f)
        end
      end

      def to_sexp
        sexp = [:evstr]
        sexp << @value.to_sexp if @value
        sexp
      end
    end
  end
end
