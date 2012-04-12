# -*- encoding: binary -*-
# :stopdoc:
class Unicorn::SSLClient < Kgio::SSL
  alias write kgio_write
  alias close kgio_close

  # this is no-op for now, to be fixed in kgio-monkey if people care
  # about SSL support...
  def shutdown(how = nil)
  end
end
