# fallback for non-Linux and Linux <4.5 systems w/o EPOLLEXCLUSIVE
class Unicorn::SelectWaiter # :nodoc:
  def get_readers(ready, readers, timeout) # :nodoc:
    ret = IO.select(readers, nil, nil, timeout) and ready.replace(ret[0])
  end
end
