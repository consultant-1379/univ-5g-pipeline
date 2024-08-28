#!/usr/bin/expect

set YANG_IP [lindex $argv 0]
set timeout 3
puts "\nChange password for user admin:\n"
spawn ssh -o StrictHostKeyChecking=no admin@$YANG_IP -p 830
expect "*Password*"
send "WeakPas-1\r"
expect "*Current Password*"
send "WeakPas-1\r"
expect "*New Password:"
send "EricSson@12-34\r"
expect "Reenter new Password:"
send "EricSson@12-34\r"
puts "\n"
sleep 5
puts "Change password for user admin-sec-netconf:\n"
spawn ssh -o StrictHostKeyChecking=no admin-sec-netconf@$YANG_IP -p 830
expect "*Password*"
send "WeakPas-1\r"
expect "*Current Password*"
send "WeakPas-1\r"
expect "*New Password:"
send "EricSson@12-34\r"
expect "Reenter new Password:"
send "EricSson@12-34\r"
sleep 15
expect eof
