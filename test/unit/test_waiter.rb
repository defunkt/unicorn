require 'test/unit'
require 'unicorn'
require 'unicorn/select_waiter'
class TestSelectWaiter < Test::Unit::TestCase

  def test_select_timeout # n.b. this is level-triggered
    sw = Unicorn::SelectWaiter.new
    IO.pipe do |r,w|
      sw.get_readers(ready = [], [r], 0)
      assert_equal [], ready
      w.syswrite '.'
      sw.get_readers(ready, [r], 1000)
      assert_equal [r], ready
      sw.get_readers(ready, [r], 0)
      assert_equal [r], ready
    end
  end

  def test_linux # ugh, also level-triggered, unlikely to change
    IO.pipe do |r,w|
      wtr = Unicorn::Waiter.prep_readers([r])
      wtr.get_readers(ready = [], [r], 0)
      assert_equal [], ready
      w.syswrite '.'
      wtr.get_readers(ready = [], [r], 1000)
      assert_equal [r], ready
      wtr.get_readers(ready = [], [r], 1000)
      assert_equal [r], ready, 'still ready (level-triggered :<)'
      assert_nil wtr.close
    end
  rescue SystemCallError => e
    warn "#{e.message} (#{e.class})"
  end if Unicorn.const_defined?(:Waiter)
end
