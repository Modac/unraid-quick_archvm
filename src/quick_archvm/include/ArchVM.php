<?PHP
/* Arch VM plugin - AJAX endpoint.
 *
 * POST action=prepare : validate the dialog input, store it as a job file and
 *                       return its id. The web UI then starts
 *                       scripts/quick_archvm_create <id> through openPlugin().
 *
 * The job file indirection means no user input ever travels through the
 * command line that Unraid's task runner builds; only a hex id does.
 * CSRF is enforced by Unraid for every POST (csrf_token is added by the UI).
 */
header('Content-Type: application/json');

function reply($data, $code = 200) {
  http_response_code($code);
  echo json_encode($data);
  exit;
}
function fail($msg) { reply(['error' => $msg], 400); }

if (($_POST['action'] ?? '') !== 'prepare') fail('unknown action');

$name    = trim($_POST['name'] ?? '');
$cpus    = $_POST['cpus'] ?? '';
$memory  = $_POST['memory'] ?? '';
$disk    = $_POST['disk'] ?? '';
$pinning = $_POST['pinning'] ?? 'auto';
$sshkey  = trim(str_replace("\r", '', $_POST['sshkey'] ?? ''));
$start   = ($_POST['start'] ?? '') === 'yes';

if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}$/', $name))
  fail('Invalid name: use letters, digits, space, dot, underscore or dash (max 63 characters).');
if (!ctype_digit((string)$cpus) || $cpus < 1 || $cpus > (int)shell_exec('nproc --all'))
  fail('Invalid number of CPUs.');
if (!ctype_digit((string)$memory) || $memory < 1)
  fail('Invalid memory size.');
if (!ctype_digit((string)$disk) || $disk < 40)
  fail('Disk size must be at least 40 GiB (the size of the Arch image).');
if (!in_array($pinning, ['auto', 'none'], true))
  fail('Invalid CPU pinning option.');
if ($sshkey !== '' && (strpos($sshkey, "\n") !== false ||
    !preg_match('/^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+ [A-Za-z0-9+\/=]+( .*)?$/', $sshkey)))
  fail('The SSH key must be a single OpenSSH public key line (ssh-ed25519 AAAA... comment).');

exec('virsh dominfo '.escapeshellarg($name).' 2>/dev/null', $out, $rc);
if ($rc === 0) fail("A VM named '$name' already exists.");

$jobdir = '/tmp/quick_archvm/jobs';
if (!is_dir($jobdir)) mkdir($jobdir, 0700, true);
foreach (glob("$jobdir/*.json") as $old) if (filemtime($old) < time() - 3600) @unlink($old);

$id = bin2hex(random_bytes(8));
$job = [
  'name' => $name, 'cpus' => (int)$cpus, 'memory' => (int)$memory, 'disk' => (int)$disk,
  'pinning' => $pinning, 'sshkey' => $sshkey, 'start' => $start,
];
if (file_put_contents("$jobdir/$id.json", json_encode($job)) === false) fail('Could not write job file.');
chmod("$jobdir/$id.json", 0600);
reply(['id' => $id]);
?>
