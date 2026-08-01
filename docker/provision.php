<?php
/*********************************************************************
    provision.php

    One-shot provisioning for the osTicket container. Run as a CLI
    script by docker/entrypoint.sh after osTicket has been installed.

    It installs and activates the community plugins requested in
    OSTICKET_PLUGINS and, for the auth-oauth2 plugin, creates and
    enables one authentication instance per configured IdP (Pocket ID,
    Google, Discord). All values come from environment variables; see
    .env.example for the full list.
**********************************************************************/

require '/var/www/html/bootstrap.php';

if (!osTicket::is_cli())
    die("Provisioning is only supported from the command line\n");

// In CLI there is no HTTP request; plugin config forms bind values the same
// way the admin UI does only when REQUEST_METHOD is POST (otherwise they
// merge in the empty saved config, which would clobber our $vars).
$_SERVER['REQUEST_METHOD'] = 'POST';

// Same bootstrap sequence as main.inc.php / manage.php CLI: load the
// config file (defines OSTINSTALLED, DB credentials, etc.), table names,
// app code, connect to the DB, and start the osTicket instance.
Bootstrap::loadConfig();
Bootstrap::defineTables(TABLE_PREFIX);
Bootstrap::loadCode();
Bootstrap::connect();

if (!($ost = osTicket::start()) || !($cfg = $ost->getConfig()))
    die("Unable to start osTicket; provisioning aborted\n");

if (!defined('OSTINSTALLED') || !OSTINSTALLED) {
    fwrite(STDERR, "osTicket is not installed yet; skipping provisioning\n");
    exit(0);
}

require_once INCLUDE_DIR.'class.plugin.php';

function logln($msg) { fwrite(STDOUT, "provision: $msg\n"); }
function err($msg) { fwrite(STDERR, "provision: ERROR: $msg\n"); }

function get_env($name) {
    $v = getenv($name);
    return ($v === false || $v === '') ? '' : $v;
}

function installed_plugin($name) {
    $all = PluginManager::allInstalled();
    return isset($all['plugins/'.$name]) ? $all['plugins/'.$name] : null;
}

function ensure_plugin($name) {
    if (($p = installed_plugin($name)) && $p->isActive())
        return $p;

    if (!$p) {
        $p = (new PluginManager)->install($name);
        if (!$p) {
            err("unable to install plugin '$name'");
            return null;
        }
    }
    $errors = array();
    if (!$p->update(array('isactive' => 1, 'notes' => ''), $errors)) {
        err("unable to activate plugin '$name': ".implode(', ', $errors));
        return null;
    }
    return $p;
}

function create_instance($plugin, $vars, $label) {
    foreach ($plugin->getInstances() as $i) {
        if (strcasecmp($i->getName(), $vars['name']) === 0) {
            logln("auth instance '$label' already present");
            return $i;
        }
    }
    $errors = array();
    $vars += array('isactive' => 1, 'notes' => '');
    if (($i = $plugin->addInstance($vars, $errors))) {
        logln("auth instance '$label' created and enabled");
    } else {
        if (!$errors && method_exists($plugin, 'getConfigForm'))
            foreach ((array) $plugin->getConfigForm($vars)->errors() as $k => $v)
                if ($k !== 'form')
                    $errors[] = "$k: $v";
        err("unable to create '$label' auth instance: ".implode(', ', $errors));
    }

    return isset($i) ? $i : null;
}

function oauth_redirect_uri() {
    $base = get_env('OSTICKET_HELPDESK_URL');
    if (!$base) {
        $cfg = new OsticketConfig();
        $base = $cfg->getBaseUrl();
    }
    return rtrim($base, '/').'/api/auth/oauth2';
}

// --- install & activate requested plugins ------------------------------
$plugins = array_filter(array_map('trim', explode(',', get_env('OSTICKET_PLUGINS'))));
$want_oauth2 = in_array('auth-oauth2', $plugins)
    || get_env('OSTICKET_OIDC_CLIENT_ID')
    || get_env('OSTICKET_GOOGLE_CLIENT_ID')
    || get_env('OSTICKET_DISCORD_CLIENT_ID');

if ($want_oauth2 && !in_array('auth-oauth2', $plugins))
    $plugins[] = 'auth-oauth2';

$loaded = array();
foreach ($plugins as $name) {
    if ($name && ($p = ensure_plugin($name))) {
        $loaded[$name] = $p;
        logln("plugin '$name' active");
    }
}

// --- auth-oauth2 instances (one per configured IdP) ---------------------
// NB: use the Plugin objects returned by ensure_plugin() above, not a fresh
// PluginManager::allInstalled() query -- osTicket's ORM caches query
// results, so a re-query right after install/activate returns stale rows
// (isactive still 0) and the instances would be skipped.
$oauth = $loaded['auth-oauth2'] ?? null;
logln("oauth2 plugin present=".($oauth ? 'yes' : 'no')." active=".($oauth && $oauth->isActive() ? 'yes' : 'no'));
if ($oauth && $oauth->isActive()) {
    $impl = $oauth->getImpl();
    $google_defaults = ($impl && method_exists($impl, 'getNewInstanceDefaults'))
        ? $impl->getNewInstanceDefaults(array('provider' => 'oauth2:google'))
        : array();

    $providers = array();

    // Pocket ID (generic OIDC)
    if (get_env('OSTICKET_OIDC_URL') && get_env('OSTICKET_OIDC_CLIENT_ID')) {
        $base = rtrim(get_env('OSTICKET_OIDC_URL'), '/');
        $name = get_env('OSTICKET_OIDC_NAME') ?: 'Pocket ID';
        $providers[] = array(
            'name'            => $name,
            'auth_name'       => $name,
            'auth_service'    => get_env('OSTICKET_OIDC_SERVICE') ?: 'Pocket ID',
            'auth_type'       => 'auth',
            'auth_target'     => get_env('OSTICKET_OIDC_AUTH_TARGET') ?: 'agents',
            'clientId'        => get_env('OSTICKET_OIDC_CLIENT_ID'),
            'clientSecret'    => get_env('OSTICKET_OIDC_CLIENT_SECRET'),
            'redirectUri'     => oauth_redirect_uri(),
            'urlAuthorize'    => $base.'/authorize',
            'urlAccessToken'  => $base.'/oauth/token',
            'urlResourceOwnerDetails' => $base.'/userinfo',
            'scopes'          => 'openid profile email',
            'attr_username'   => get_env('OSTICKET_OIDC_ATTR_USERNAME') ?: 'preferred_username',
            'attr_email'      => 'email',
            'attr_givenname'  => 'given_name',
            'attr_surname'    => 'family_name',
        );
    }

    // Google (built-in provider template)
    if (get_env('OSTICKET_GOOGLE_CLIENT_ID')) {
        $name = get_env('OSTICKET_GOOGLE_NAME') ?: 'Google';
        $providers[] = array_merge($google_defaults, array(
            'name'         => $name,
            'auth_name'    => $name,
            'auth_service' => get_env('OSTICKET_GOOGLE_SERVICE') ?: 'Google',
            'auth_type'    => 'auth',
            'auth_target'  => get_env('OSTICKET_GOOGLE_AUTH_TARGET') ?: 'agents',
            'clientId'     => get_env('OSTICKET_GOOGLE_CLIENT_ID'),
            'clientSecret' => get_env('OSTICKET_GOOGLE_CLIENT_SECRET'),
            'redirectUri'  => oauth_redirect_uri(),
        ));
    }

    // Discord (generic OAuth2)
    if (get_env('OSTICKET_DISCORD_CLIENT_ID')) {
        $name = get_env('OSTICKET_DISCORD_NAME') ?: 'Discord';
        $providers[] = array(
            'name'            => $name,
            'auth_name'       => $name,
            'auth_service'    => get_env('OSTICKET_DISCORD_SERVICE') ?: 'Discord',
            'auth_type'       => 'auth',
            'auth_target'     => get_env('OSTICKET_DISCORD_AUTH_TARGET') ?: 'agents',
            'clientId'        => get_env('OSTICKET_DISCORD_CLIENT_ID'),
            'clientSecret'    => get_env('OSTICKET_DISCORD_CLIENT_SECRET'),
            'redirectUri'     => oauth_redirect_uri(),
            'urlAuthorize'    => 'https://discord.com/oauth2/authorize',
            'urlAccessToken'  => 'https://discord.com/api/oauth2/token',
            'urlResourceOwnerDetails' => 'https://discord.com/api/users/@me',
            'scopes'          => 'identify email',
            'attr_username'   => 'username',
            'attr_email'      => 'email',
        );
    }

    foreach ($providers as $vars)
        create_instance($oauth, $vars, $vars['name']);
    logln("oauth2 providers configured: ".count($providers));
}

// --- auth-2fa instance ---------------------------------------------------
$tfa = $loaded['auth-2fa'] ?? null;
logln("2fa plugin present=".($tfa ? 'yes' : 'no')." active=".($tfa && $tfa->isActive() ? 'yes' : 'no')." instances=".($tfa ? $tfa->getInstances()->count() : 0));
if ($tfa && $tfa->isActive() && !$tfa->getInstances()->count())
    create_instance($tfa, array('name' => 'Two Factor Auth'), 'Two Factor Auth');

// --- system language --------------------------------------------------------
// The installer never persists the wizard's lang_id into system_language, so
// enforce the declared OSTICKET_LANG here. Runs on every start (declarative,
// like the plugin instances above and TRUSTED_PROXIES in the entrypoint).
$lang = get_env('OSTICKET_LANG');
$current = $cfg->getPrimaryLanguage();
if ($lang && $current !== $lang) {
    $cfg->set('system_language', $lang);
    logln("system_language set to '$lang' (was '$current')");
}
