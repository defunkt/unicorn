%%{

  machine unicorn_http_common;

#### HTTP PROTOCOL GRAMMAR
# line endings
  CRLF = ("\r\n" | "\n");

# character types
  CTL = (cntrl | 127);
  safe = ("$" | "-" | "_" | ".");
  extra = ("!" | "*" | "'" | "(" | ")" | ",");
  reserved = (";" | "/" | "?" | ":" | "@" | "&" | "=" | "+");
  sorta_safe = ("\"" | "<" | ">");
  unsafe = (CTL | " " | "#" | "%" | sorta_safe);
  national = any -- (alpha | digit | reserved | extra | safe | unsafe);
  unreserved = (alpha | digit | safe | extra | national);
  escape = ("%" xdigit xdigit);
  uchar = (unreserved | escape | sorta_safe);
  pchar = (uchar | ":" | "@" | "&" | "=" | "+");
  tspecials = ("(" | ")" | "<" | ">" | "@" | "," | ";" | ":" | "\\" | "\"" | "/" | "[" | "]" | "?" | "=" | "{" | "}" | " " | "\t");
  lws = (" " | "\t");
  content = ((any -- CTL) | lws);

# elements
  token = (ascii -- (CTL | tspecials));

# URI schemes and absolute paths
  scheme = ( "http"i ("s"i)? ) $downcase_char >mark %scheme;
  hostname = ((alnum | "-" | "." | "_")+ | ("[" (":" | xdigit)+ "]"));
  host_with_port = (hostname (":" digit*)?) >mark %host;
  userinfo = ((unreserved | escape | ";" | ":" | "&" | "=" | "+")+ "@")*;

  path = ( pchar+ ( "/" pchar* )* ) ;
  query = ( uchar | reserved )* %query_string ;
  param = ( pchar | "/" )* ;
  params = ( param ( ";" param )* ) ;
  rel_path = (path? (";" params)? %request_path) ("?" %start_query query)?;
  absolute_path = ( "/"+ rel_path );
  path_uri = absolute_path > mark %request_uri;
  Absolute_URI = (scheme "://" userinfo host_with_port path_uri);

  Request_URI = ((absolute_path | "*") >mark %request_uri) | Absolute_URI;
  Fragment = ( uchar | reserved )* >mark %fragment;
  Method = (token){1,20} >mark %request_method;
  GetOnly = "GET" >mark %request_method;

  http_number = ( digit+ "." digit+ ) ;
  HTTP_Version = ( "HTTP/" http_number ) >mark %http_version ;
  Request_Line = ( Method " " Request_URI ("#" Fragment){0,1} " " HTTP_Version CRLF ) ;

  field_name = ( token -- ":" )+ >start_field $snake_upcase_field %write_field;

  field_value = content* >start_value %write_value;

  value_cont = lws+ content* >start_value %write_cont_value;

  message_header = ((field_name ":" lws* field_value)|value_cont) :> CRLF;
  Trailers := (message_header)* CRLF @end_trailers;

  FullRequest = Request_Line (message_header)* CRLF @header_done;
  SimpleRequest = GetOnly " " Request_URI ("#"Fragment){0,1} CRLF @header_done;

main := FullRequest | SimpleRequest;

}%%
