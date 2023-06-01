# -*- encoding: binary -*-
# compatibility module for Ruby <= 2.4, remove when we go Ruby 2.5+
module Unicorn::WriteSplat # :nodoc:
  def write(*arg) # :nodoc:
    super(arg.join(''))
  end
end
