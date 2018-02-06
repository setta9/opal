# frozen_string_literal: true

require 'set'
require 'pathname'
require 'opal/nodes/base'
require 'opal/nodes/runtime_helpers'
require 'opal/rewriters/break_finder'

module Opal
  module Nodes
    class CallNode < Base
      handle :send

      attr_reader :recvr, :meth, :arglist, :iter

      SPECIALS = {}

      # Operators that get optimized by compiler
      OPERATORS = { :+ => :plus, :- => :minus, :* => :times, :/ => :divide,
                    :< => :lt, :<= => :le, :> => :gt, :>= => :ge }

      def self.add_special(name, options = {}, &handler)
        SPECIALS[name] = options
        define_method("handle_#{name}", &handler)
      end

      def initialize(*)
        super
        @recvr, @meth, *args = *@sexp

        *rest, last_arg = *args

        if last_arg && [:iter, :block_pass].include?(last_arg.type)
          @iter = last_arg
          args = rest
        else
          @iter = nil
        end

        @arglist = s(:arglist, *args)
      end

      def compile
        # handle some methods specially
        # some special methods need to skip compilation, so we pass the default as a block
        handle_special do
          compiler.method_calls << meth.to_sym if record_method?

          # if trying to access an lvar in irb mode
          return compile_irb_var if using_irb?

          default_compile
        end
      end

      private

      def iter_has_break?
        return false unless iter

        finder = Opal::Rewriters::BreakFinder.new
        finder.process(iter)
        finder.found_break?
      end

      # Opal has a runtime helper 'Opal.send_method_name' that assigns
      # provided block to a '$$p' property of the method body
      # and invokes a method using 'apply'.
      #
      # We have to compile a method call using this 'Opal.send_method_name' when a method:
      # 1. takes a splat
      # 2. takes a block
      #
      # Arguments that contain splat must be handled in a different way.
      # @see #compile_arguments
      #
      # When a method takes a block we have to calculate all arguments
      # **before** asigning '$$p' property (that stores a passed block)
      # to a method body. This is some kind of protection from method calls
      # like 'a(a {}) { 1 }'.
      def invoke_using_send?
        iter || splat?
      end

      def default_compile
        if invoke_using_send?
          compile_using_send
        else
          compile_simple_call_chain
        end

        compile_break_catcher
      end

      # Compiles method call using `Opal.send`
      #
      # @example
      #   a.b(c, &block)
      #
      #   Opal.send(a, 'b', [c], block)
      #
      def compile_using_send
        helper :send

        push '$send('
        compile_receiver
        compile_method_name
        compile_arguments
        compile_block_pass
        push ')'
      end

      def compile_receiver
        push recv(receiver_sexp)
      end

      def compile_method_name
        push ", '#{meth}'"
      end

      def compile_arguments
        push ", "

        if splat?
          push expr(arglist)
        elsif arglist.children.empty?
          push '[]'
        else
          push '[', expr(arglist), ']'
        end
      end

      def compile_block_pass
        if iter
          push ", ", expr(iter)
        end
      end

      def compile_break_catcher
        if iter_has_break?
          unshift 'return '
          unshift '(function(){var $brk = Opal.new_brk(); try {'
          line '} catch (err) { if (err === $brk) { return err.$v } else { throw err } }})()'
        end
      end

      def compile_simple_call_chain
        push recv(receiver_sexp), method_jsid, "(", expr(arglist), ")"
      end

      def splat?
        arglist.children.any? { |a| a.type == :splat }
      end

      def receiver_sexp
        recvr || s(:self)
      end

      def method_jsid
        mid_to_jsid meth.to_s
      end

      def record_method?
        true
      end

      # Used to generate the code to use this sexp as an ivar var reference
      def compile_irb_var
        with_temp do |tmp|
          lvar = meth
          call = s(:send, s(:self), meth.intern, s(:arglist))
          push "((#{tmp} = Opal.irb_vars.#{lvar}) == null ? ", expr(call), " : #{tmp})"
        end
      end

      # a variable reference in irb mode in top scope might be a var ref,
      # or it might be a method call
      def using_irb?
        @compiler.irb? && scope.top? && arglist == s(:arglist) && recvr.nil? && iter.nil?
      end

      def sexp_with_arglist
        @sexp.updated(nil, [recvr, meth, arglist])
      end

      # Handle "special" method calls, e.g. require(). Subclasses can override
      # this method. If this method returns nil, then the method will continue
      # to be generated by CallNode.
      def handle_special(&compile_default)
        if SPECIALS.include? meth
          method = method("handle_#{meth}")
          method.arity == 1 ? method[compile_default] : method[]
        elsif RuntimeHelpers.compatible?(recvr, meth)
          push(RuntimeHelpers.new(sexp_with_arglist, @level, @compiler).compile)
        else
          yield
        end
      end

      OPERATORS.each do |operator, name|
        add_special(operator.to_sym) do |compile_default|
          if compiler.inline_operators?
            compiler.method_calls << operator.to_sym if record_method?
            compiler.operator_helpers << operator.to_sym
            lhs, rhs = expr(recvr), expr(arglist)

            push fragment("$rb_#{name}(")
            push lhs
            push fragment(", ")
            push rhs
            push fragment(")")
          else
            compile_default.call
          end
        end
      end

      add_special :require do |compile_default|
        str = DependencyResolver.new(compiler, arglist.children[0]).resolve
        compiler.requires << str unless str.nil?
        compile_default.call
      end

      add_special :require_relative do
        arg = arglist.children[0]
        file = compiler.file
        if arg.type == :str
          dir = File.dirname(file)
          compiler.requires << Pathname(dir).join(arg.children[0]).cleanpath.to_s
        end
        push fragment("self.$require(#{file.inspect}+ '/../' + ")
        push process(arglist)
        push fragment(')')
      end

      add_special :autoload do |compile_default|
        if scope.class_scope?
          str = DependencyResolver.new(compiler, arglist.children[1]).resolve
          compiler.requires << str unless str.nil?
          compile_default.call
        end
      end

      add_special :require_tree do |compile_default|
        first_arg, *rest = *arglist.children
        if first_arg.type == :str
          relative_path = first_arg.children[0]
          compiler.required_trees << relative_path

          dir = File.dirname(compiler.file)
          full_path = Pathname(dir).join(relative_path).cleanpath.to_s
          full_path.force_encoding(relative_path.encoding)
          first_arg = first_arg.updated(nil, [full_path])
        end
        @arglist = arglist.updated(nil, [first_arg] + rest)
        compile_default.call
      end

      add_special :block_given? do
        push compiler.handle_block_given_call @sexp
      end

      add_special :__callee__ do
        if scope.def?
          push fragment scope.mid.to_s.inspect
        else
          push fragment 'nil'
        end
      end

      add_special :__method__ do
        if scope.def?
          push fragment scope.mid.to_s.inspect
        else
          push fragment 'nil'
        end
      end

      add_special :debugger do
        push fragment 'debugger'
      end

      add_special :__OPAL_COMPILER_CONFIG__ do
        push fragment "Opal.hash({ arity_check: #{compiler.arity_check?} })"
      end

      add_special :nesting do |compile_default|
        push_nesting = push_nesting?
        push '(Opal.Module.$$nesting = $nesting, ' if push_nesting
        compile_default.call
        push ')' if push_nesting
      end

      add_special :constants do |compile_default|
        push_nesting = push_nesting?
        push '(Opal.Module.$$nesting = $nesting, ' if push_nesting
        compile_default.call
        push ')' if push_nesting
      end

      def push_nesting?
        recv = children.first

        children.size == 2 && (           # only receiver and method
          recv.nil? || (                  # and no receiver
            recv.type == :const &&        # or receiver
            recv.children.last == :Module # is Module
          )
        )
      end

      class DependencyResolver
        def initialize(compiler, sexp)
          @compiler = compiler
          @sexp = sexp
        end

        def resolve
          handle_part @sexp
        end

        def handle_part(sexp)
          type = sexp.type

          if type == :str
            return sexp.children[0]
          elsif type == :send
            recv, meth, *args = sexp.children

            parts = args.map { |s| handle_part s }

            if ::Opal::AST::Node === recv && recv.type == :const && recv.children.last == :File
              if meth == :expand_path
                return expand_path(*parts)
              elsif meth == :join
                return expand_path parts.join('/')
              elsif meth == :dirname
                return expand_path parts[0].split('/')[0...-1].join('/')
              end
            end
          end

          msg = "Cannot handle dynamic require"
          case @compiler.dynamic_require_severity
          when :error
            @compiler.error msg, @sexp.line
          when :warning
            @compiler.warning msg, @sexp.line
          end
        end

        def expand_path(path, base = '')
          "#{base}/#{path}".split("/").inject([]) do |p, part|
            if part == ''
              # we had '//', so ignore
            elsif part == '..'
              p.pop
            else
              p << part
            end

            p
          end.join "/"
        end
      end
    end
  end
end
