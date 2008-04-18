'#--
'# Copyright (c) 2006-2007 Luis Lavena, Multimedia systems
'#
'# This source code is released under the MIT License.
'# See MIT-LICENSE file for details
'#++

#include once "console_process.bi"
#include once "file.bi"
#include once "testly.bi"
#include once "test_helpers.bi"

namespace Suite_Test_Console_Process
    '# test helpers
    declare function process_cleanup() as boolean
    
    dim shared child as ConsoleProcess ptr
    
    sub before_all()
        kill("out.log")
        kill("err.log")
        kill("both.log")
        kill("both_slow.log")
        kill("both_forced.log")
    end sub
    
    sub after_each()
        process_cleanup()
    end sub
    
    sub test_process_create()
        child = new ConsoleProcess()
        assert_not_equal_error(0, child)
        assert_equal("", child->filename)
        assert_equal("", child->arguments)
        assert_false(child->running)
        delete child
    end sub
    
    sub test_process_create_args()
        child = new ConsoleProcess("mock_process.exe", "some params")
        assert_equal("mock_process.exe", child->filename)
        assert_equal("some params", child->arguments)
        delete child
    end sub
    
    sub test_properly_quoted_filename()
        child = new ConsoleProcess("C:\path with spaces\my_executable.exe", "some params")
        assert_not_equal(0, instr(child->filename, !"\""))
        delete child
    end sub
    
    sub test_failed_unexistant_process()
        child = new ConsoleProcess("no_valid_file.exe", "some params")
        assert_false(child->start())
        assert_equal(0, child->pid)
        assert_false(child->running)
        delete child
    end sub
    
    sub test_process_spawn_exit_code()
        child = new ConsoleProcess("mock_process.exe", "error")
        
        '# start() should return true since it started, no matter if was terminated
        '# improperly
        assert_true(child->start())
        sleep 150
        
        '# should not be running, but pid should be != than 0
        assert_not_equal(0, child->pid)
        
        '# we need to wait a bit prior asking for state
        '# the process could be still running
        assert_false(child->running)
        
        '# get exit code, should be 1
        assert_equal(1, child->exit_code)
        
        delete child
    end sub
    
    sub test_redirected_output()
        '# redirected output is used with logging files.
        child = new ConsoleProcess("mock_process.exe")
        
        '# redirect stdout
        assert_true(child->redirect(ProcessStdOut, "out.log"))
        assert_string_equal("out.log", child->redirected_stdout)
        
        '# redirect stderr
        assert_true(child->redirect(ProcessStdErr, "err.log"))
        assert_string_equal("err.log", child->redirected_stderr)
        
        '# start() will be true since process terminated nicely
        assert_true(child->start())
        sleep 150
        
        '# running should be false
        assert_false(child->running)
        
        '# exit_code should be 0
        assert_equal(0, child->exit_code)
        
        '# now out.log and err.log must exist and content must be valid.
        assert_true(fileexists("out.log"))
        assert_string_equal("out: message", content_of_file("out.log"))
        
        assert_true(fileexists("err.log"))
        assert_string_equal("err: error", content_of_file("err.log"))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("out.log"))
        assert_equal_error(0, kill("err.log"))
        
        assert_true_error(fileexists("err.log"))
        
        delete child
    end sub
    
    sub test_redirected_merged_output()
        dim content as string
        
        '# redirected output is used with logging files.
        child = new ConsoleProcess("mock_process.exe")

        '# redirect both stdout and stderr 
        child->redirect(ProcessStdBoth, "both.log")
        assert_equal("both.log", child->redirected_stdout)
        assert_equal("both.log", child->redirected_stderr)
        
        '# start() will be true since process terminated nicely
        assert_true(child->start())
        sleep 150
        
        '# running should be false
        assert_false(child->running)
        
        '# exit_code should be 0
        assert_equal(0, child->exit_code)
        
        '# file must exists
        assert_true(fileexists("both.log"))
        
        '# contents must match
        content = content_of_file("both.log")
        
        assert_not_equal(0, instr(content, "out: message"))
        assert_not_equal(0, instr(content, "err: error"))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("both.log"))
        
        delete child
    end sub
    
    sub test_redirected_output_append()
        dim content as string
        
        child = new ConsoleProcess("mock_process.exe")
        
        '# redirect both stdout and stderr 
        child->redirect(ProcessStdBoth, "both.log")
        
        '# start() will be true since process terminated nicely
        assert_true(child->start())
        sleep 150
        
        content = content_of_file("both.log")
        
        '# start() again
        assert_true(child->start())
        sleep 150
        
        assert_not_equal(len(content), len(content_of_file("both.log")))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("both.log"))
        
        delete child
    end sub
    
    sub test_process_terminate()
        dim content as string
        
        '# redirected output is used with logging files.
        child = new ConsoleProcess("mock_process.exe", "wait")
        child->redirect(ProcessStdBoth, "both.log")
        
        '# start
        assert_true(child->start())
        sleep 150
        
        '# validate if running
        assert_true(child->running)
        
        '# validate PID
        assert_not_equal(0, child->pid)
        
        '# now terminates it
        assert_true(child->terminate())
        sleep 150
        
        assert_equal(9, child->exit_code)
        
        '# it should be done
        assert_false(child->running)
        
        '# validate output
        '# file must exists
        assert_true(fileexists("both.log"))
        
        '# contents must match
        content = content_of_file("both.log")
        
        assert_not_equal(0, instr(content, "out: message"))
        assert_not_equal(0, instr(content, "err: error"))
        assert_not_equal(0, instr(content, "interrupted"))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("both.log"))
        
        delete child
    end sub
    
    sub test_process_terminate_slow()
        dim content as string
        
        '# redirected output is used with logging files.
        child = new ConsoleProcess("mock_process.exe", "slow")
        child->redirect(ProcessStdBoth, "both_slow.log")
        
        '# start
        assert_true(child->start())
        sleep 150
        
        '# validate if running
        assert_true(child->running)
        
        '# validate PID
        assert_not_equal(0, child->pid)
        
        '# now terminates it
        assert_true(child->terminate())
        sleep 150
        
        '# it should be done now
        assert_false(child->running)
        assert_equal(10, child->exit_code)
        
        '# validate output
        '# file must exists
        assert_true(fileexists("both_slow.log"))
        
        '# contents must match
        content = content_of_file("both_slow.log")
        
        assert_not_equal(0, instr(content, "out: message"))
        assert_not_equal(0, instr(content, "err: error"))
        assert_not_equal(0, instr(content, "out: slow stop"))
        assert_equal(0, instr(content, "interrupted"))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("both_slow.log"))
        
        delete child
    end sub
    
    sub test_process_terminate_forced()
        dim content as string
        dim x as integer
        
        '# redirected output is used with logging files.
        child = new ConsoleProcess("mock_process.exe", "wait")
        child->redirect(ProcessStdBoth, "both_forced.log")
        
        '# start
        assert_true(child->start())
        sleep 150
        
        '# validate if running
        assert_true(child->running)
        
        '# validate PID
        assert_not_equal(0, child->pid)
        
        '# now terminates it
        assert_true(child->terminate(true))
        sleep 150
        
        '# it should be done
        assert_false(child->running)
        
        '# look for termination code
        assert_equal(0, child->exit_code)
        
        '# validate output
        '# file must exists
        assert_true(fileexists("both_forced.log"))
        
        '# contents must match
        content = content_of_file("both_forced.log")
        
        assert_equal(0, instr(content, "out: message"))
        assert_equal(0, instr(content, "err: error"))
        assert_equal(0, instr(content, "interrupted"))
        
        '# cleanup
        process_cleanup()
        assert_equal_error(0, kill("both_forced.log"))
        
        delete child
    end sub
    
    sub test_reuse_object_instance()
        dim first_pid as uinteger
        
        child = new ConsoleProcess("mock_process.exe")
        
        '# start
        assert_true(child->start())
        sleep 150
        
        '# validate not running
        assert_false(child->running)
        
        '# validate PID
        assert_not_equal(0, child->pid)
        
        '# saves PID
        first_pid = child->pid
        
        '# start it again
        assert_true(child->start())
        sleep 150
        
        '# it should have stopped by now
        assert_false(child->running)
        assert_not_equal(0, child->pid)
        assert_not_equal(first_pid, child->pid)
        
        '# cleanup
        process_cleanup()
        
        delete child
    end sub
    
    private sub register() constructor
        add_suite(Suite_Test_Console_Process)
        add_test(test_process_create)
        add_test(test_process_create_args)
        add_test(test_properly_quoted_filename)
        add_test(test_failed_unexistant_process)
        add_test(test_process_spawn_exit_code)
        add_test(test_redirected_output)
        add_test(test_redirected_merged_output)
        add_test(test_redirected_output_append)
        add_test(test_process_terminate)
        add_test(test_process_terminate_slow)
        add_test(test_process_terminate_forced)
        add_test(test_reuse_object_instance)
    end sub
    
    '# test helpers below this point
    private function process_cleanup() as boolean
        shell "taskkill /f /im mock_process.exe 1>NUL 2>&1"
        return true
    end function
end namespace
