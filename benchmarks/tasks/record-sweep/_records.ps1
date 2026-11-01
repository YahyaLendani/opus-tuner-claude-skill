# Generates the record files the same way everywhere. A small generator of its own,
# because System.Random's sequence is not promised across .NET versions.
function Get-RecordFiles {
    $words = @('amber', 'basalt', 'cobalt', 'delta', 'ember', 'fjord', 'granite', 'harbor', 'indigo', 'juniper', 'krypton', 'lagoon', 'meadow', 'nickel', 'onyx', 'pewter', 'quartz', 'russet', 'sienna', 'tundra')
    $owners = @('alice', 'bilal', 'chen', 'dara', 'eve')
    $seed = [int64]20261006
    $files = @{}
    for ($f = 1; $f -le 40; $f++) {
        $lines = New-Object System.Collections.ArrayList
        for ($l = 1; $l -le 300; $l++) {
            $seed = ($seed * 1103515245 + 12345) % 2147483648
            $pick = [int](($seed -shr 8) % 1000)
            $status = 'OK'; $owner = $owners[$pick % 5]
            if ($pick -lt 5) { $status = 'HOLD'; $owner = '-' }
            elseif ($pick -lt 30) { $status = 'HOLD' }
            elseif ($pick -lt 60) { $owner = '-' }
            $note = New-Object System.Collections.ArrayList
            for ($w = 0; $w -lt 7; $w++) {
                $seed = ($seed * 1103515245 + 12345) % 2147483648
                [void]$note.Add($words[[int](($seed -shr 8) % 20)])
            }
            [void]$lines.Add(('R{0:00}{1:000} status={2} owner={3} note={4}' -f $f, $l, $status, $owner, ($note -join '-')))
        }
        $files[('records-{0:00}.txt' -f $f)] = $lines
    }
    return $files
}
