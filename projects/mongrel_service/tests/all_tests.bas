'#--
'# Copyright (c) 2006-2007 Luis Lavena, Multimedia systems
'#
'# This source code is released under the MIT License.
'# See MIT-LICENSE file for details
'#++

#include once "testly.bi"

'# the code in this module runs after all 
'# the other modules have "registered" their suites.

'# evaluate the result from run_tests() to
'# return a error to the OS or not.
if (run_tests() = false) then
    end 1
end if

