#!/bin/expect -f

# exp_internal 1
log_user 0
set timeout -1


proc defined_or_default {varname def} {
    upvar $varname var
    if {![info exists var]} {
        set var $def
    }
}

set config $::env(HOME)/.config/kp-dmenu/config.tcl
if {[file exists $config]} {
    source $config
} else {
    puts stderr "Provide config file at $config"
    exit 1
}

if {![info exists kp_database_path]} {
    puts stderr {Variable $kp_database_path must be defined}
    exit 1
} elseif {![file exists $kp_database_path]} {
    puts stderr "Database file not found at $kp_database_path"
    exit 1
}


defined_or_default kp_dmenu {rofi -dmenu -i}
defined_or_default kp_pinentry /usr/bin/pinentry-qt

set kp_appdir /tmp/kp-dmenu/
file mkdir $kp_appdir
exec chmod 700 $kp_appdir
cd $kp_appdir


proc pinentry_get {} {
    spawn "$::kp_pinentry"
    expect "OK"
    send -- "SETDESC Enter Password for $::kp_database_path:\r"
    expect "OK"
    send -- "GETPIN\r"
    expect "OK"
    regexp -line {D (.*)\r} $expect_out(buffer) line pw
    send -- "BYE\r"
    wait
    return $pw
}

proc run {kp_pw} {
    spawn keepassxc-cli open "$::kp_database_path"
    expect "Enter password"
    send -- "$kp_pw\r"
    expect "> "
    if {[regexp {Invalid credentials} $expect_out(buffer) match]} {
        puts stderr "Wrong Password"
        exit 1
    }
         
    send -- "ls -R -f\r"
    expect "> "

    set kp_accounts {}
    foreach line [lrange [split $expect_out(buffer) "\n"] 1 end] {
        set item [string trim $line]
        if {($item eq "") || ([string index $item end] in {">" "/"})} {
            continue
        }
        lappend kp_accounts $item
    }

    set window [exec xdotool getactivewindow]
    if {[catch {exec {*}$::kp_dmenu << [join $kp_accounts "\n"]} result] == 0} {
        send -- "show -s \"$result\"\r"
        expect "> "
        regexp -line {^Password: (.*)\r} $expect_out(buffer) line kp_entry_pw

        exec {*}{xdotool -} << "
             windowactivate --sync $window
             type --clearmodifiers -- $kp_entry_pw
        "        
    }
    
    send -- "quit\r"
    wait
}


### GET PASSWORD
set kp_pw [pinentry_get]
run $::kp_pw


### Go into background and listen on the FIFO
proc readpipe {} {
    if {[gets $::pipe line] > 0} {
        if {![string eq $line exit]} {
            run $::kp_pw
        } else {
            cleanup
        }
    }
}

proc cleanup {} {
    close $::pipe
    file delete -force -- $::kp_appdir
    exit 0
}


if {[fork] != 0} {
    # parent
    exit
}

# child    
disconnect
trap {cleanup} {SIGTERM SIGINT}

set kp_pipe run
exec mkfifo $kp_pipe

set pipe [open "$kp_pipe" {RDWR NONBLOCK}]
fileevent $pipe readable readpipe

if {[info exists kp_timeout]} {
    set ::state waiting
    after [expr {60000 * $kp_timeout}] {set ::state timeout}
    vwait ::state
} else {
    vwait forever
}

cleanup
exit
