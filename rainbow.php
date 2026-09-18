#!/fsMinimalKernel/php
<?php
// rainbow.php -- dessine un arc-en-ciel plein ecran directement dans le
// framebuffer Linux (/dev/fb0), sans aucune bibliotheque graphique (pas
// de X11/Wayland/SDL/GD -- juste des octets bruts au bon format pixel).
// Pense pour tourner sous le kernel minimal (pas de gd/ffi/ioctl
// disponibles dans le build PHP statique), donc la resolution et le
// format sont lus dans /sys/class/graphics/fb0 plutot que via ioctl.
//
// Format pixel suppose : 32 bits, little-endian, XRGB8888 (donc en
// memoire, octet par octet : Bleu, Vert, Rouge, [inutilise]) -- c'est
// le format standard de l'emulation fbdev des pilotes DRM modernes
// (i915 inclus, celui de ce Dell).

$FB  = '/dev/fb0';
$SYS = '/sys/class/graphics/fb0';

function read_sys(string $path, string $name): string
{
    $v = @file_get_contents("$path/$name");
    if ($v === false) {
        fwrite(STDERR, "Impossible de lire $path/$name\n");
        exit(1);
    }
    return trim($v);
}

[$width, $height] = array_map('intval', explode(',', read_sys($SYS, 'virtual_size')));
$bpp = (int) read_sys($SYS, 'bits_per_pixel');

if ($bpp !== 32) {
    fwrite(STDERR, "bits_per_pixel=$bpp non supporte par ce script (32 attendu)\n");
    exit(1);
}
$bytespp = intdiv($bpp, 8);

$stride = is_file("$SYS/stride")
    ? (int) read_sys($SYS, 'stride')
    : $width * $bytespp;

function pixel_bytes(int $r, int $g, int $b): string
{
    // XRGB8888 little-endian => en memoire : B, G, R, X(=0)
    return pack('V', ($r << 16) | ($g << 8) | $b);
}

// Rouge (exterieur) -> violet (interieur) : ordre physique d'un vrai
// arc-en-ciel (le rouge est toujours sur le bord exterieur de l'arc).
$colors = [
    [255,   0,   0], // rouge
    [255, 127,   0], // orange
    [255, 255,   0], // jaune
    [  0, 200,   0], // vert
    [  0,   0, 255], // bleu
    [ 75,   0, 130], // indigo
    [148,   0, 211], // violet
];
$nbands    = count($colors);
$bandBytes = array_map(fn(array $c) => pixel_bytes(...$c), $colors);

$bgColor = pixel_bytes(8, 8, 30); // bleu nuit
$bgRow   = str_repeat($bgColor, $width);
$padding = str_repeat("\x00", max(0, $stride - $width * $bytespp));

// Arc centre au milieu-bas de l'ecran, rayon adapte a la resolution
// courante -- fonctionne quelle que soit la taille de l'ecran.
$cx        = intdiv($width, 2);
$cy        = $height;
$outerR    = min($cx, $height) * 0.95;
$bandWidth = $outerR / ($nbands + 1); // +1 : marge au centre du dome

// Verification d'acces une seule fois au demarrage (message d'erreur
// clair si /dev/fb0 est absent ou inaccessible).
$fp = fopen($FB, 'r+b');
if ($fp === false) {
    fwrite(STDERR, "Impossible d'ouvrir $FB (droits ? peripherique absent ?)\n");
    exit(1);
}
fclose($fp);

function draw_frame(string $fb, array $bandBytes): void
{
    global $width, $height, $cx, $cy, $outerR, $bandWidth, $nbands, $bgRow, $padding, $bytespp;

    $rows = [];
    for ($y = 0; $y < $height; $y++) {
        $dy = $cy - $y;

        if ($dy >= $outerR) {
            // Au-dessus du dome de l'arc : ciel uni.
            $rows[] = $bgRow . $padding;
            continue;
        }

        $row = $bgRow;
        for ($i = 0; $i < $nbands; $i++) {
            $rOut = $outerR - $i * $bandWidth;
            if ($dy >= $rOut) {
                continue; // cette bande ne touche pas cette ligne
            }
            $rIn = $rOut - $bandWidth;

            $dxMax = sqrt(max(0.0, $rOut * $rOut - $dy * $dy));
            $dxMin = ($dy >= $rIn) ? 0.0 : sqrt(max(0.0, $rIn * $rIn - $dy * $dy));

            $xRightStart = max(0, min($width, $cx + (int) floor($dxMin)));
            $xRightEnd   = max(0, min($width, $cx + (int) ceil($dxMax)));
            $xLeftStart  = max(0, min($width, $cx - (int) ceil($dxMax)));
            $xLeftEnd    = max(0, min($width, $cx - (int) floor($dxMin)));

            if ($xRightEnd > $xRightStart) {
                $len = $xRightEnd - $xRightStart;
                $row = substr_replace($row, str_repeat($bandBytes[$i], $len), $xRightStart * $bytespp, $len * $bytespp);
            }
            if ($xLeftEnd > $xLeftStart) {
                $len = $xLeftEnd - $xLeftStart;
                $row = substr_replace($row, str_repeat($bandBytes[$i], $len), $xLeftStart * $bytespp, $len * $bytespp);
            }
        }

        $rows[] = $row . $padding;
    }

    // Un seul fwrite() pour toute l'image, plutot qu'un par ligne : sur
    // certaines cartes, la taille reelle exploitable du framebuffer via
    // /dev/fb0 est plus petite que stride*hauteur annonce par
    // /sys/class/graphics/fb0/virtual_size (qui peut inclure une zone
    // "virtuelle" de panoramique non retournee par un write() direct).
    // Avec un fwrite() par ligne, chaque ligne au-dela de cette limite
    // echouait individuellement avec ENOSPC -- des centaines
    // d'avertissements "No space left on device". Un seul gros fwrite()
    // ecrit tout ce qui rentre en un coup et s'arrete proprement sur le
    // reste (silencieux via "@" : c'est attendu, pas une erreur).
    //
    // fopen/fclose a CHAQUE frame plutot qu'un handle garde ouvert :
    // /dev/fb0 n'est pas un fichier "regulier" pour PHP, qui marque ce
    // type de flux non-seekable (avertissement "fseek(): Stream does
    // not support seeking") independamment de ce que le noyau
    // autoriserait reellement -- impossible de revenir au debut du
    // fichier pour la 2e frame avec le meme handle. Reouvrir donne a
    // chaque fois un descripteur frais, donc une position de depart 0
    // garantie.
    $fp = fopen($fb, 'r+b');
    if ($fp !== false) {
        @fwrite($fp, implode('', $rows));
        fclose($fp);
    }
}

// Redessine toutes les 2 secondes en faisant tourner l'ordre des
// couleurs des bandes (rouge devient orange, orange devient jaune,
// etc.) -- une rotation simple d'un tableau, pas un recalcul des
// rayons. Ctrl+C (SIGINT) termine le script normalement (aucun handler
// installe -- comportement par defaut de PHP).
while (true) {
    draw_frame($FB, $bandBytes);
    sleep(2);
    array_unshift($bandBytes, array_pop($bandBytes));
}
