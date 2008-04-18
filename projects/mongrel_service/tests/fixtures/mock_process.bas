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

dim shared as any ptr control_signal, control_mutex
dim shared flagged as byte
dim shared result as integer

function slow_console_handler(byval dwCtrlType as DWORD) as BOOL
    dim result as BOOL
    
    if (dwCtrlType = CTRL_C_EVENT) then
        fprintf(stdout, !"out: CTRL-C received\r\n")
        mutexlock(control_mutex)
        result = 1
        flagged = 1
        condsignal(control_signal)
        mutexunlock(control_mutex)
    elseif (dwCtrlType = CTRL_BREAK_EVENT) then
        fprintf(stdout, !"out: CTRL-BREAK received\r\n")
        mutexlock(control_mutex)
        result = 1
        flagged = 2
        condsignal(control_signal)
        mutexunlock(control_mutex)
    end if
    
    return result
end function

sub wait_for(byval flag_level as integer)
    flagged = 0
    '# set handler
    if (SetConsoleCtrlHandler(@slow_console_handler, 1) = 0) then
        fprintf(stderr, !"err: cannot set console handler\r\n")
    end if
    fprintf(stdout, !"out: waiting for keyboard signal\r\n")
    mutexlock(control_mutex)
    do until (flagged = flag_level)
        condwait(control_signal, control_mutex)
    loop
    mutexunlock(control_mutex)
    fprintf(stdout, !"out: got keyboard signal\r\n")
    if (SetConsoleCtrlHandler(@slow_console_handler, 0) = 0) then
        fprintf(stderr, !"err: cannot unset console handler\r\n")
    end if
end sub

function main() as integer
    fprintf(stdout, !"out: message\r\n")
    fprintf(stderr, !"err: error\r\n")
    
    select case lcase(command(1))
        case "wait":
            sleep
            return 0

        case "error":
            '# terminate with error code
            return 1
        
        case "slow1":
            wait_for(1)
            return 10
        
        case "slow2":
            wait_for(2)
            return 20
    end select
end function

control_signal = condcreate()
control_mutex = mutexcreate()

result = main()

conddestroy(control_signal)
mutexdestroy(control_mutex)

end result
