package Plugins::HueBridge::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use XML::Simple;

use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::HueBridge::HueCom;

my $log   = logger('plugin.huebridge');
my $prefs = preferences('plugin.huebridge');

my $XMLConfig;
my @XMLConfigSaveDeviceOptions = qw(name user_name mac codecs enabled remove_count server);

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_HUEBRIDGE_NAME');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/HueBridge/settings/basic.html');
}

sub prefs {
    return ( $prefs, qw(binaryAutorun showAdvancedHueBridgeOptions) );
}

sub beforeRender {
    my ($class, $params) = @_;
    
    if( Plugins::HueBridge::HueCom->getConnectProgress() || Plugins::HueBridge::HueCom->getConnectDisconnectStatus() ) {
        $params->{'statusHueBridgeConnect'} = 1;
    }
    else {
        $params->{'statusHueBridgeConnect'} = 0;
    }
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    $XMLConfig = readXMLConfigFile(KeyAttr => 'device');

    if ( $params->{'deleteSqueeze2HueXMLConfig'} ) {
        
        my $conf = Plugins::HueBridge::Squeeze2Hue->configFile();
        unlink $conf;
    
        $log->debug('Deleting Squeeze2Hue XML configuration file ('. $conf .')');
    
        delete $params->{'saveSettings'};
    }

    if ( $params->{'generateSqueeze2HueXMLConfig'} ) {
    
        $log->debug('Generating Squeeze2Hue XML configuration file.');    
        # put routine for generating XML config here.
        
        delete $params->{'saveSettings'};
    }
    
    if ( $params->{'cleanSqueeze2HueLogFile'} ) {

        my $logFile = Plugins::HueBridge::Squeeze2Hue->logFile();
        $log->debug('Cleaning Squeeze2Hue helper log file ' . $logFile . ')');
        
        open my $fileHandle, ">", $logFile;
        print $fileHandle;
        close $fileHandle;

        delete $params->{'saveSettings'};
    }

    if ( $params->{'startSqueeze2Hue'} ) {
    
        $log->debug('Trigggered \'start\' of Squeeze2Hue binary.');
        Plugins::HueBridge::Squeeze2Hue->start();
        
        delete $params->{'saveSettings'};
    }
    
    if ( $params->{'stopSqueeze2Hue'} ) {
    
        $log->debug('Triggered \'stop\' of Squeeze2Hue binary.');
        Plugins::HueBridge::Squeeze2Hue->stop();
        
        delete $params->{'saveSettings'};
    }
    
    if ( $params->{'restartSqueeze2Hue'} ) {
    
        $log->debug('Triggered \'restart\' of Squeeze2Hue binary.');
        Plugins::HueBridge::Squeeze2Hue->restart();
        
        delete $params->{'saveSettings'};
    }

    if ( $prefs->get('binaryAutorun') ) {
        $params->{'binaryRunning'} = Plugins::HueBridge::Squeeze2Hue->alive();
    }
    else {
        $params->{'binaryRunning'} = 0;
    }
    
    $params->{'helperBinary'}   = Plugins::HueBridge::Squeeze2Hue->getHelperBinary();
    $params->{'availableHelperBinaries'} = [ Plugins::HueBridge::Squeeze2Hue->getAvailableHelperBinaries() ];

    for( my $i = 0; defined($params->{"connectHueBridgeButtonHelper$i"}); $i++ ) {
        if( $params->{"connectHueBridge$i"} ){
            
            my $deviceUDN = $params->{"connectHueBridgeButtonHelper$i"};
            
            $log->debug('Triggered \'connect\' of device with udn: ' . $deviceUDN);
            Plugins::HueBridge::HueCom->connect( $deviceUDN, $XMLConfig );
            
            delete $params->{'saveSettings'};
        }
    }

    if ( $params->{'saveSettings'}) {
    #   Plugins::HueBridge::HueCom->getConnectedHueBridge();
    #   If something changed: Put it into the XMLConfig hash, stop the helper, write to file, start the helper.
    #   Add await handler.
    #   Save player specific parameters       
        foreach my $huebridge ($XMLConfig->{'device'}) {

            for my $deviceOption (@XMLConfigSaveDeviceOptions) {
                if ($params->{ $deviceOption } eq '') {
                    delete $huebridge->{ $deviceOption };
                }
                else {
                    $huebridge->{ $deviceOption } = $params->{ $deviceOption };
                }
            }	
        }

        # Put some restart routine here for reloading the XMLConfig.
    }

    return $class->SUPER::handler($client, $params, $callback, \@args);
}

sub handler_tableAdvancedHueBridgeOptions {
    my ($client, $params) = @_;
    
    if ( $XMLConfig && $prefs->get('showAdvancedHueBridgeOptions') ) {
    
        return Slim::Web::HTTP::filltemplatefile("plugins/HueBridge/settings/tableAdvancedHueBridgeOptions.html", $params);
    }
}

sub handler_tableHueBridges {
    my ($client, $params) = @_;
    
    # Put in some progress/reload handler for updated XMLConfig.
    
    if ( $XMLConfig->{'device'} ) {

        $params->{'huebridges'} = $XMLConfig->{'device'};
        return Slim::Web::HTTP::filltemplatefile("plugins/HueBridge/settings/tableHueBridges.html", $params);
    }
}

sub findUDN {
    my $udn = shift(@_);
    my $listpar = shift(@_);
    my @list = @{$listpar};

    while (@list) {

        my $p = pop @list;
        if ($p->{ 'udn' } eq $udn) { return $p; }
    }

    return undef;
}

sub readXMLConfigFile {
    my (@args) = @_;
    my $ret;

    my $file = Plugins::HueBridge::Squeeze2Hue->configFile();

    if (-e $file) {
        $ret = XMLin($file, ForceArray => ['device'], KeepRoot => 0, NoAttr => 1, @args);
    }	

    return $ret;
}

1;
