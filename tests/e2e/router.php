<?php
// Router per `php -S`: file statici di public/ come sono, il resto a index.php.
// Prima del checkout public/index.php non esiste ancora: 503.
$public = getenv('E2E_PUBLIC');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path !== '/' && is_file($public . $path)) {
    return false;
}
if (!is_file($public . '/index.php')) {
    http_response_code(503);
    exit;
}
chdir($public);
require $public . '/index.php';
