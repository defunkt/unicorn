'#--
'# Copyright (c) 2006-2007 Luis Lavena, Multimedia systems
'#
'# This source code is released under the MIT License.
'# See MIT-LICENSE file for details
'#++

'# this program mock a common process that will:
'# output some text to stdout
'# output some error messages to stderr
'# will wait until Ctrl-C is hit (only if commandline contains "wait")
'# or drop an error if commandline contains "error"

#include once "crt.bi"
#include once "windows.bi"

dim shared stop_hit as BOOL

function _console_handler(byval dwCtrlType as DWORD) as BOOL
    dim result as BOOL
    
    if (dwCtrlType = CTRL_C_EVENT) then
        '# slow response, take 10 seconds...
        fprintf(stdout, !"out: slow stop\r\n")
        sleep (10*1000)
        result = 1
        stop_hit = TRUE
    end if
    
    return result
end function

sub main()
    fprintf(stdout, !"out: message\r\n")
    fprintf(stderr, !"err: error\r\n")
    
    select case lcase(command(1))
        case "wait":
            sleep
            
        case "error":
            '# terminate with error code
            end 1
            
        case "slow":
            stop_hit = FALSE
            SetConsoleCtrlHandler(@_console_handler, 1)
            do while (stop_hit = FALSE)
                sleep 15
            loop
            SetConsoleCtrlHandler(@_console_handler, 0)
            end 10
    end select
end sub

main()
