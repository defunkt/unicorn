# -*- encoding: binary -*-
# frozen_string_literal: false
# :enddoc:
# Writes a Rack response to your client using the HTTP/1.1 specification.
# You use it by simply doing:
#
#   status, headers, body = rack_app.call(env)
#   http_response_write(socket, status, headers, body)
#
# Most header correctness (including Content-Length and Content-Type)
# is the job of Rack, with the exception of the "Date" and "Status" header.
module Unicorn::HttpResponse

  STATUS_CODES = defined?(Rack::Utils::HTTP_STATUS_CODES) ?
                 Rack::Utils::HTTP_STATUS_CODES : {}
  STATUS_WITH_NO_ENTITY_BODY = defined?(
                 Rack::Utils::STATUS_WITH_NO_ENTITY_BODY) ?
                 Rack::Utils::STATUS_WITH_NO_ENTITY_BODY : begin
    warn 'Rack::Utils::STATUS_WITH_NO_ENTITY_BODY missing'
    {}
  end

  # internal API, code will always be common-enough-for-even-old-Rack
  def err_response(code, response_start_sent)
    "#{response_start_sent ? '' : 'HTTP/1.1 '}" \
      "#{code} #{STATUS_CODES[code]}\r\n\r\n"
  end

  def append_header(buf, key, value)
    case value
    when Array # Rack 3
      value.each { |v| buf << "#{key}: #{v}\r\n" }
    when /\n/ # Rack 2
      # avoiding blank, key-only cookies with /\n+/
      value.split(/\n+/).each { |v| buf << "#{key}: #{v}\r\n" }
    else
      buf << "#{key}: #{value}\r\n"
    end
  end

  # writes the rack_response to socket as an HTTP response
  def http_response_write(socket, status, headers, body,
                          req = Unicorn::HttpRequest.new)
    hijack = nil
    do_chunk = false
    if headers
      code = status.to_i
      msg = STATUS_CODES[code]
      start = req.response_start_sent ? ''.freeze : 'HTTP/1.1 '.freeze
      term = STATUS_WITH_NO_ENTITY_BODY.include?(code) || false
      buf = "#{start}#{msg ? %Q(#{code} #{msg}) : status}\r\n" \
            "Date: #{httpdate}\r\n" \
            "Connection: close\r\n"
      headers.each do |key, value|
        case key
        when %r{\A(?:Date|Connection)\z}i
          next
        when %r{\AContent-Length\z}i
          append_header(buf, key, value)
          term = true
        when %r{\ATransfer-Encoding\z}i
          append_header(buf, key, value)
          term = true if /\bchunked\b/i === value # value may be Array :x
        when "rack.hijack"
          # This should only be hit under Rack >= 1.5, as this was an illegal
          # key in Rack < 1.5
          hijack = value
        else
          append_header(buf, key, value)
        end
      end
      if !hijack && !term && req.chunkable_response?
        do_chunk = true
        buf << "Transfer-Encoding: chunked\r\n".freeze
      end
      socket.write(buf << "\r\n".freeze)
    end

    if hijack
      req.hijacked!
      hijack.call(socket)
    elsif do_chunk
      begin
        body.each do |b|
          socket.write("#{b.bytesize.to_s(16)}\r\n", b, "\r\n".freeze)
        end
      ensure
        socket.write("0\r\n\r\n".freeze)
      end
    else
      body.each { |chunk| socket.write(chunk) }
    end
  end
end
