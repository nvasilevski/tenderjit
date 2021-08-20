class TenderJIT
  class Runtime
    def initialize fisk, jit_buffer
      @fisk       = fisk
      @labels     = []
      @jit_buffer = jit_buffer

      yield self
    end

    def jump location
      flush
      pos = @jit_buffer.pos
      rel_jump = 0xcafe
      2.times do
        @jit_buffer.seek(pos, IO::SEEK_SET)
        Fisk.new { |__| __.jmp(__.rel32(rel_jump)) }.write_to(@jit_buffer)
        rel_jump = location - (@jit_buffer.memory.to_i + @jit_buffer.pos)
      end
    end

    def flush
      @fisk.assign_registers(TenderJIT::ISEQCompiler::SCRATCH_REGISTERS, local: true)
      @fisk.write_to(@jit_buffer)
      @fisk = Fisk.new
    end

    def pointer reg, type: Fiddle::TYPE_VOIDP, offset: 0
      if reg.is_a? TemporaryVariable
        reg = reg.reg
      end
      Pointer.new reg, type, find_size(type), offset, self
    end

    def sub reg, val
      @fisk.sub reg, @fisk.uimm(val)
    end

    def write_memory reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, val)
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def write_immediate reg, offset, val
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.uimm(val))
        @fisk.mov(@fisk.m64(reg, offset), tmp)
      end
    end

    def read_to_reg src, offset
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, @fisk.m64(src, offset))
        yield tmp
      end
    end

    def with_ref reg, offset
      @fisk.with_register do |tmp|
        @fisk.lea(tmp, @fisk.m(reg, offset))
        yield tmp
      end
    end

    def write_register dst, offset, src
      @fisk.mov(@fisk.m64(dst, offset), src)
    end

    def break
      @fisk.int(@fisk.lit(3))
    end

    def test_flags obj, flags
      lhs = cast_to_fisk obj
      rhs = cast_to_fisk flags
      @fisk.test lhs, rhs
      @fisk.jz push_label  # else label
      finish_label = push_label
      yield
      @fisk.jmp finish_label # finish label
      self
    end

    def if_eq lhs, rhs
      lhs = cast_to_fisk lhs
      rhs = cast_to_fisk rhs

      maybe_reg lhs do |op1|
        maybe_reg rhs do |op2|
          @fisk.cmp op1, op2
        end
      end
      @fisk.jne push_label # else label
      finish_label = push_label
      yield
      @fisk.jmp finish_label # finish label
      self
    end

    def else
      finish_label = pop_label
      else_label = pop_label
      @fisk.put_label else_label
      yield
      @fisk.put_label finish_label
    end

    # Dereference an operand in to a temp register and yield the register
    #
    # Basically just:
    #   `mov(tmp_reg, operand)`
    #
    def dereference operand
      @fisk.with_register do |tmp|
        @fisk.mov(tmp, operand)
        yield tmp
      end
    end

    class TemporaryVariable
      attr_reader :reg

      def initialize reg, fisk
        @reg  = reg
        @fisk = fisk
      end

      # Write something to the temporary variable
      def write operand
        @fisk.mov(@reg, operand)
      end

      # Release the temporary variable (say you are done using its value)
      def release!
        @fisk.release_register @reg
      end
    end

    # Create a temporary variable
    def temp_var
      TemporaryVariable.new @fisk.register, @fisk
    end

    private

    def push_label
      label = "label #{@labels.length}"
      @labels.push label
      @fisk.label label
    end

    def pop_label
      @labels.pop
    end

    def maybe_reg op
      if op.immediate? && op.size == 64
        @fisk.with_register do |tmp|
          @fisk.mov(tmp, op)
          yield tmp
        end
      else
        yield op
      end
    end

    def cast_to_fisk val
      if val.is_a?(Fisk::Operand)
        val
      else
        @fisk.uimm(val)
      end
    end

    def find_size type
      type == Fiddle::TYPE_VOIDP ? Fiddle::SIZEOF_VOIDP : type.size
    end

    class Array
      attr_reader :reg, :type, :size

      def initialize reg, type, size, offset, event_coordinator
        @reg    = reg
        @type   = type
        @size   = size
        @offset = offset
        @ec     = event_coordinator
      end

      def [] idx
        Fisk::M64.new(@reg, @offset + (idx * size))
      end
    end

    class Pointer
      attr_reader :reg, :type, :size

      def initialize reg, type, size, base, event_coordinator
        @reg    = reg
        @type   = type
        @size   = size
        @base   = base
        @ec     = event_coordinator
      end

      def [] idx
        Fisk::M64.new(@reg, @base + (idx * size))
      end

      def []= idx, val
        if val.is_a?(Fisk::Operand)
          if val.memory?
            @ec.write_memory @reg, idx * size, val
          else
            raise NotImplementedError
          end
        else
          @ec.write_immediate @reg, idx * size, val
        end
      end

      # Mutates this pointer.  Subtracts the size from itself.  Similar to
      # C's `--` operator
      def sub
        @ec.sub reg, size
      end

      def with_ref offset
        @ec.with_ref(@reg, @base + (offset * size)) do |reg|
          yield Pointer.new(reg, type, size, 0, @ec)
        end
      end

      def method_missing m, *values
        return super if type == Fiddle::TYPE_VOIDP

        member = m.to_s
        v      = values.first

        read = true

        if m =~ /^(.*)=/
          member = $1
          read = false
        end

        if read
          if idx = type.members.index { |n, _| n == member }
            sub_type = type.types[idx]
            if sub_type.respond_to?(:entity_class)
              return Pointer.new(@reg, sub_type, sub_type.size, @base + type.offsetof(member), @ec)
            end
          end
        end

        return super unless type.members.include?(member)

        if read
          if block_given?
            @ec.read_to_reg(@reg, type.offsetof(member)) do |reg|
              yield reg
            end
          else
            subtype = type.types[type.members.index(member)]
            if subtype.is_a?(::Array)
              Array.new(reg, subtype.first, Fiddle::PackInfo::SIZE_MAP[subtype.first], @base + type.offsetof(member), @ec)
            else
              return Fisk::M64.new(@reg, @base + type.offsetof(member))
            end
          end

        else
          if v.is_a?(Pointer)
            @ec.write_register @reg, type.offsetof(member), v.reg
          else
            @ec.write_immediate @reg, type.offsetof(member), v.to_i
          end
        end
      end
    end
  end
end