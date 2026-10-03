# Changelog

## 1.0.0

First release.

- Prints a QR code label for every Shelf asset tagged `QRP`, through Home Assistant's Niimbot integration.
- Swaps the tag for `QRU` once Home Assistant confirms the print, so Shelf shows which assets have a label.
- Keeps the tag and retries every minute if the printer is off or out of range.
- QR codes use Shelf's own links, so scans open the asset and are recorded as usual. Longer Shelf addresses are scaled to fit the 12 mm printhead.
- Text size adjusts to the label length; long names are shortened with "…".
- Optional status page showing waiting, printing and printed labels, and the printer's battery and connection.
- Settings for tag names, label length, left margin, rotation, print density and the Shelf database container.
