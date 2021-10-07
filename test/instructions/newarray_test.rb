# frozen_string_literal: true

require "helper"

class TenderJIT
  class NewarrayTest < JITTest
    def bar; 1; end

    def empty_array
      []
    end

    def filled_array
      [bar, bar, bar]
    end

    def test_empty_array
      mm = method(:empty_array)
      assert_has_insn mm, insn: :newarray

      jit.compile(mm)
      jit.enable!
      v = empty_array
      jit.disable!

      assert_equal 1, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [], v
    end

    def test_newarray_filled
      mm = method(:filled_array)
      assert_has_insn mm, insn: :newarray

      jit.compile(mm)
      jit.enable!
      v = filled_array
      jit.disable!

      assert_equal 2, jit.compiled_methods
      assert_equal 0, jit.exits
      assert_equal [1, 1, 1], v
    end
  end
end
