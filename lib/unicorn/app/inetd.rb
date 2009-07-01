# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

# this class *must* be used with Rack::Chunked

module Unicorn::App
  class Inetd

    class CatBody
      def initialize(env, cmd)
        @cmd = cmd
        @input, @errors = env['rack.input'], env['rack.errors']
        in_rd, in_wr = IO.pipe
        @err_rd, err_wr = IO.pipe
        @out_rd, out_wr = IO.pipe

        @cmd_pid = fork {
          inp, out, err = (0..2).map { |i| IO.new(i) }
          inp.reopen(in_rd)
          out.reopen(out_wr)
          err.reopen(err_wr)
          [ in_rd, in_wr, @err_rd, err_wr, @out_rd, out_wr ].each { |io|
            io.close
          }
          exec(*cmd)
        }
        [ in_rd, err_wr, out_wr ].each { |io| io.close }
        [ in_wr, @err_rd, @out_rd ].each { |io| io.binmode }
        in_wr.sync = true

        # Unfortunately, input here must be processed inside a seperate
        # thread/process using blocking I/O since env['rack.input'] is not
        # IO.select-able and attempting to make it so would trip Rack::Lint
        @inp_pid = fork {
          [ @err_rd, @out_rd ].each { |io| io.close }
          buf = Unicorn::Z.dup

          # this is dependent on @input.read having readpartial semantics:
          while @input.read(16384, buf)
            in_wr.write(buf)
          end
          in_wr.close
        }
        in_wr.close
      end

      def each(&block)
        buf = Unicorn::Z.dup
        begin
          rd, = IO.select([@err_rd, @out_rd])
          rd && rd.first or next

          if rd.include?(@err_rd)
            begin
              @errors.write(@err_rd.read_nonblock(16384, buf))
            rescue Errno::EINTR
            rescue Errno::EAGAIN
              break
            end while true
          end

          rd.include?(@out_rd) or next

          begin
            yield @out_rd.read_nonblock(16384, buf)
          rescue Errno::EINTR
          rescue Errno::EAGAIN
            break
          end while true
        rescue EOFError,Errno::EPIPE,Errno::EBADF,Errno::EINVAL
          break
        end while true

        self
      end

      def close
        @input = nil
        [ [ @cmd.inspect, @cmd_pid ], [ 'input streamer', @inp_pid ]
        ].each { |str, pid|
          begin
            pid, status = Process.waitpid2(pid)
            status.success? or
              @errors.write("#{str}: #{status.inspect} (PID:#{pid})\n")
          rescue Errno::ECHILD
            @errors.write("Failed to reap #{str} (PID:#{pid})\n")
          end
        }
      end

    end

    def initialize(*cmd)
      @cmd = cmd
    end

    def call(env)
      expect = env[Unicorn::Const::HTTP_EXPECT] and
        /\A100-continue\z/i =~ expect and
          return [ 100, {} , [] ]

      [ 200, { 'Content-Type' => 'application/octet-stream' },
       CatBody.new(env, @cmd) ]
    end

  end

end
