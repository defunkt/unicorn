'#--
'# Copyright (c) 2006-2007 Luis Lavena, Multimedia systems
'#
'# This source code is released under the MIT License.
'# See MIT-LICENSE file for details
'#++

#include once "testly.bi"
#include once "test_helpers.bi"
#include once "file.bi"

'# Global Helpers
function content_of_file(byref filename as string) as string
    dim result as string
    dim handle as integer
    dim buffer as string
    
    result = ""
    buffer = ""
    
    if (fileexists(filename) = true) then
        handle = freefile
        open filename for input as #handle
        do while not (eof(handle))
            input #handle, buffer
            result += buffer
            buffer = ""
        loop
        close #handle
    else
        result = ""
    end if
    
    return result
end function
