# -*- encoding: binary -*-
# :stopdoc:
class Unicorn::SSLClient < Kgio::SSL
  alias write kgio_write
  alias close kgio_close
end
