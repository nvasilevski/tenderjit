# frozen_string_literal: true

require "helper"

class TenderJIT
  class SendTest < JITTest
    def test_send
      skip "Please implement send!"
    end

    def bar
      5
    end

    def foo
      bar { }
    end

    def test_send_with_block
      jit.compile(method(:foo))
      jit.enable!
      v = foo
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 5, v
    end

    def barr
      yield
    end

    def foor
      barr { 5 }
    end

    def test_send_with_block_yields
      jit.compile(method(:foor))
      jit.enable!
      v = foor
      jit.disable!

      assert_equal 3, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal 5, v
    end

    def run_each x
      i = 0
      x.each { |m| i += m }
      i
    end

    def test_cfunc_with_block
      jit.compile(method(:run_each))

      expected = run_each([1, 2, 3])
      jit.enable!
      actual = run_each([1, 2, 3])
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal expected, actual
    end
  end
end
