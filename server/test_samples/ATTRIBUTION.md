# External test corpus — attribution

`external_*` images were downloaded from Wikimedia Commons for gate
verification (domain-gate false-accept / false-reject testing). They are
unmodified test fixtures; resized copies (max 800 px wide) as served by the
Commons thumbnail API. Licenses require attribution — this file is it.

Source page: `https://commons.wikimedia.org/wiki/File:<title>`

## Must-be-rejected (non-fundus) — `03_adversarial_non_fundus/`

| File | Commons title | Author | License |
|---|---|---|---|
| `external_face_portrait.jpg` | Elderly Gambian woman face portrait.jpg | Ferdinand Reus | CC BY-SA 2.0 |
| `external_face_closeup.jpg` | Henrietta Szold close-up (cropped).jpg | Alexander Ganan | CC BY 3.0 |
| `external_selfie.jpg` | Selfie Chania.jpg | Jebulon | CC0 |
| `external_receipt_document.jpg` | Receipt for supplies for the "Votes for Women" Pageant and Parade, May 2, 1914.jpg | Connecticut Woman Suffrage Association | Public domain |
| `external_desk_workspace.jpg` | Brown and beige, Computer desk, Rostov-on-Don, Russia.jpg | Vyacheslav Argenberg | CC BY 4.0 |
| `external_landscape_outdoors.jpg` | Mesic meadow in sagebrush landscape (53125720487).jpg | USFWS Mountain Prairie | Public domain |
| `external_screenshot_desktop.png` | Kubuntu 21.04 Desktop en.png | Diego Carvalho | CC BY-SA 4.0 |

## Must-never-be-rejected (real fundus) — `01_real_clinical_fundus/`

| File | Commons title | Author | License |
|---|---|---|---|
| `external_fundus_right_eye.jpg` | Fundus photo right eye.jpg | Meri Vukicevic | CC BY-SA 3.0 |
| `external_fundus_normal.jpg` | Fundus photograph-normal retina EDA06.JPG | (not stated) | Public domain |
| `external_fundus_circular.jpg` | Right eye fundus photograph.jpg | Jan Kaláb (Brno, Czech Republic) | CC BY-SA 2.0 |

CC BY-SA files are used unmodified as test data. If this fixture folder is
redistributed outside the repository, keep this attribution file with it.
