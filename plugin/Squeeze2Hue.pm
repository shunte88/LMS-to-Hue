package Plugins::HueBridge::Squeeze2Hue;

use strict;

use Proc::Background;
use File::Spec::Functions;
use Data::Dumper;
use XML::Simple qw(:strict);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::HueBridge::Settings;

my $prefs = preferences('plugin.huebridge');
my $log   = logger('plugin.huebridge');

my $squeeze2hue;
my $squeeze2hueRestartStatus;
my $squeeze2hueRestartCounter = 0;
my $squeeze2hueRestartCounterTimeWait = 15;

sub initCLICommands {
    # Command init
    #    |requires client
    #    |  |is a query
    #    |  |  |has tags
    #    |  |  |  |function to call
    #    C  Q  T  F
    
    Slim::Control::Request::addDispatch(['hue', 'bridge', 'restart','?'],
        [0, 1, 0, \&CLI_commandGetSqueeze2hueRestartProgress]);
}

sub CLI_commandGetSqueeze2hueRestartProgress {
    my $request = shift;
    
    $request->addResult('_hueBridgeRestartProgress', sprintf("%.2f", getRestartProgress()));
    
    $request->setStatusDone();
}

sub getAvailableBinaries {
	my $os = Slim::Utils::OSDetect::details();
	
	if ($os->{'os'} eq 'Linux') {

		if ($os->{'osArch'} =~ /x86_64/) {
		
			return qw(squeeze2hue-x86-64 squeeze2hue-x86-64-static);
		}
		
		if ($os->{'binArch'} =~ /i386/) {
		
			return qw(squeeze2hue-x86 squeeze2hue-x86-static);
		}
		
		if ($os->{'binArch'} =~ /armhf/) {
		
			return qw(squeeze2hue-armv6hf squeeze2hue-armv6hf-static);
		}
		
		if ($os->{'binArch'} =~ /arm/) {
		
			return qw(squeeze2hue-armv5te squeeze2hue-armv5te-static);
		}
		
		# fallback to offering all linux options for case when architecture detection does not work
		return qw(squeeze2hue-x86-64 squeeze2hue-x86-64-static squeeze2hue-x86 squeeze2hue-x86-static squeeze2hue-armv6hf squeeze2hue-armv6hf-static);
	}
	
	if ($os->{'os'} eq 'Unix') {
	
		if ($os->{'osName'} eq 'solaris') {
		
			return qw(squeeze2hue-i86pc-solaris squeeze2hue-i86pc-solaris-static);
		}	
		
	}	
	
	if ($os->{'os'} eq 'Darwin') {
	
		return qw(squeeze2hue-osx-multi squeeze2hue-osx-multi-static);
	}
	
	if ($os->{'os'} eq 'Windows') {
	
		return qw(squeeze2hue-win.exe);
	}	
	
=comment	
		if ($os->{'isWin6+'} ne '') {
		
			return qw(squeeze2hue-win.exe);
		}
		else {
		
			return qw(squeeze2hue-winxp.exe);
		}	
	}
=cut	
	
}

sub getBinary {
	my @availableBinaries = getAvailableBinaries();

	if (scalar @availableBinaries == 1) {
	
		return $availableBinaries[0];
	}

	if (my $b = $prefs->get('binary')) {
	
		for my $binary (@availableBinaries) {
		
			if ($binary eq $b) {
			
				return $b;
			}
		}
	}

	return undef;
}

sub start {
	my $binary = Plugins::HueBridge::Squeeze2Hue->getBinary() || do {
		$log->warn('Squeeze2Hue binary not set.');
		return;
	};

	my @params;
	my $loggingEnabled;

	push @params, ("-Z");
	
	if ($prefs->get('autosave')) {
	
		push @params, ("-I");
	}
	
	if ($prefs->get('eraselog')) {
	
		unlink Plugins::HueBridge::Squeeze2Hue->logFile();
	}
	
	if ($prefs->get('useLMSsocket')) {
	
		push @params, ("-b", Slim::Utils::Network::serverAddr());
	}

	if ($prefs->get('loggingEnabled')) {
	
		push @params, ("-f", Plugins::HueBridge::Squeeze2Hue->logFile() );
		
		if ($prefs->get('debugs') ne '') {
		
			push @params, ("-d", $prefs->get('debugs') . "=debug");
		}
		$loggingEnabled = 1;
	}
	
	if (-e Plugins::HueBridge::Squeeze2Hue->configFile() || $prefs->get('autosave')) {
	
		push @params, ("-x", Plugins::HueBridge::Squeeze2Hue->configFile(),
                       "-c", Slim::Utils::OSDetect::dirsFor('cache')
        );
	}
	
	if ($prefs->get('opts') ne '') {
	
		push @params, split(/\s+/, $prefs->get('opts'));
	}
	
	if (Slim::Utils::OSDetect::details()->{'os'} ne 'Windows') {
	
		my $exec = catdir(Slim::Utils::PluginManager->allPlugins->{'HueBridge'}->{'basedir'}, 'Bin', $binary);
		$exec = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($exec);
			
		if (!((stat($exec))[2] & 0100)) {
		
			$log->warn('Squeeze2Hue binary not having \'x\' permission, correcting.');
			chmod (0555, $exec);
		}	
	}	
	
	my $path = Slim::Utils::Misc::findbin($binary) || do {
		$log->warn($binary. ' not found.');
		return;
	};

	my $path = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($path);
			
	if (!-e $path) {
	
		$log->warn($binary. ' not executable.');
		return;
	}
	
	push @params, @_;

    $log->debug('Starting Squeeze2Hue binary (' . $path . ' ' . join(" ", @params) . ')');
	
	eval { $squeeze2hue = Proc::Background->new({ 'die_upon_destroy' => 1 }, $path, @params); };

	if ($@) {

		$log->warn($@);

	}
	else {
	
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
			if ($squeeze2hue && $squeeze2hue->alive() ) {
				$log->debug($binary. ' running.');
				$binary = $path;
			}
			else {
				$log->debug($binary. ' not running.');
			}
		});
		
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 30, \&beat, $path, @params);
	}
}

sub beat {
	my ($path, @args) = @_;
	
	if ($prefs->get('autorun') && !($squeeze2hue && $squeeze2hue->alive)) {
	
		$log->error('crashed ... restarting');
		
		eval { $squeeze2hue = Proc::Background->new({ 'die_upon_destroy' => 1 }, $path, @args); };
	}	
	
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 30, \&beat, $path, @args);
}

sub stop {

	if ($squeeze2hue && $squeeze2hue->alive()) {
	
		$log->info("Stopping Squeeze2Hue binary.");
		$squeeze2hue->die;
	}
}

sub alive {
	return ($squeeze2hue && $squeeze2hue->alive) ? 1 : 0;
}

sub wait {
	$log->info("Waiting for Squeeze2Hue binary to end");
	$squeeze2hue->wait
}

sub restart {
    my ($self, $arg) = @_;
    
    if ( ! $arg ) {
    
        $log->debug('Squeeze2Hue plain restart requested.');
    }
    elsif ( $arg eq 'genXMLConfig') {
    
        $log->debug('Squeeze2Hue XMLConfig generation requested.');
    }
    elsif ( ref($arg) eq 'HASH' ) {

        $log->debug('Squeeze2Hue XMLConfig config file update requested.');
    }

    Plugins::HueBridge::Squeeze2Hue->stop();
    $squeeze2hueRestartCounter = 0;
        
    Slim::Utils::Timers::setTimer(undef, time() + 1, \&_performRestart,
                                                    {
                                                            arg => $arg,
                                                    },
                                                );

    Slim::Utils::Timers::setTimer(undef, time() + $squeeze2hueRestartCounterTimeWait, \&unrestart);

    $squeeze2hueRestartStatus = 1;
}

sub _performRestart {
    my ($self, $params) = @_;
    my $arg = $params->{'arg'};

    $squeeze2hueRestartCounter++;
    
    if ( $squeeze2hueRestartCounter == POSIX::floor($squeeze2hueRestartCounterTimeWait * .3) ) {
    
        if ( ! $arg ) {
        }
        elsif ( $arg eq 'genXMLConfig' ) {
        }
        elsif ( ref($arg) eq 'HASH' ) {

            $log->debug('Squeeze2Hue XMLConfig writing data to file (' . Plugins::HueBridge::Squeeze2Hue->configFile() . ').');
            Plugins::HueBridge::Squeeze2Hue->writeXMLConfigFile($arg);
        }
    }
    elsif ( $squeeze2hueRestartCounter == POSIX::floor($squeeze2hueRestartCounterTimeWait * .7) ) {
        
        if ( ! $arg ) {
            
            $log->debug('Squeeze2Hue restarting.');
            Plugins::HueBridge::Squeeze2Hue->start();
        }
        elsif ( $arg eq 'genXMLConfig' ) {
            
            $log->debug('Squeeze2Hue restarting and generating new config file.');
            Plugins::HueBridge::Squeeze2Hue->start("-i", Plugins::HueBridge::Squeeze2Hue->configFile() );
        }
        elsif ( ref($arg) eq 'HASH' ) {
            
            $log->debug('Squeeze2Hue restarting after config file update.');
            Plugins::HueBridge::Squeeze2Hue->start();
        }
    }
    Slim::Utils::Timers::setTimer(undef, time() + 1, \&_performRestart,
                                                    {
                                                            arg => $arg,
                                                    },
                                                );
}

sub unrestart{
    $log->debug('Terminating Squeeze2Hue XMLConfig restart.');
    
    Slim::Utils::Timers::killTimers(undef, \&_performRestart);
    Slim::Utils::Timers::killTimers(undef, \&unrestart);

    $squeeze2hueRestartCounter = 0;
    $squeeze2hueRestartStatus = 0;
}

sub getRestartProgress {
    my $returnValue;

    if ( $squeeze2hueRestartCounter >= 0.0 ) {

        $returnValue =  $squeeze2hueRestartCounter / $squeeze2hueRestartCounterTimeWait;
    }
    else {

        $returnValue = $squeeze2hueRestartCounter;
    }

    return $returnValue;
}

sub getRestartStatus {
    return $squeeze2hueRestartStatus;
}

sub logFile {
    my $self = shift;
	return catdir(Slim::Utils::OSDetect::dirsFor('log'), "huebridge.log");
}

sub configFile {
    my $self = shift;
	return catdir(Slim::Utils::OSDetect::dirsFor('prefs'), $prefs->get('xmlConfigFileName'));
}

sub readXMLConfigFile {
    my ($self, @args) = @_;
    my $ret;

    my $file = Plugins::HueBridge::Squeeze2Hue->configFile();

    if (-e $file) {
        $ret = XMLin($file, ForceArray => [ qw(device) ], KeepRoot => 0, NoAttr => 1, KeyAttr => [ qw(device) ], @args);
    }

    return $ret;
}

sub writeXMLConfigFile {
    my ($self, $configData) = @_;

    my $configFile = Plugins::HueBridge::Squeeze2Hue->configFile();
    
    XMLout($configData, RootName => "squeeze2hue", KeyAttr => [], NoSort => 1, NoAttr => 1, OutputFile => $configFile);
}

1;
