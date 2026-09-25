-- K123598: compare the model's predicate list with an independent OCR list
-- (97 distinct K-numbers from Tesseract OCR of pages 1-4; OCR can be wrong too).
WITH ocr_truth(k) AS (
  VALUES
    ('K001942'), ('K002747'), ('K002996'), ('K003274'), ('K011836'), ('K021178'),
    ('K021803'), ('K022556'), ('K022902'), ('K022958'), ('K023302'), ('K024134'),
    ('K030971'), ('K031162'), ('K031165'), ('K032709'), ('K033442'), ('K040680'),
    ('K042127'), ('K043252'), ('K052275'), ('K052426'), ('K052792'), ('K053246'),
    ('K060630'), ('K061243'), ('K061253'), ('K070278'), ('K070756'), ('K070928'),
    ('K071160'), ('K072852'), ('K080625'), ('K081566'), ('K082371'), ('K083566'),
    ('K083762'), ('K092098'), ('K092386'), ('K093363'), ('K093991'), ('K100412'),
    ('K100481'), ('K102370'), ('K103256'), ('K110101'), ('K823722'), ('K823723'),
    ('K823724'), ('K823725'), ('K823726'), ('K823727'), ('K823728'), ('K823729'),
    ('K831884'), ('K834592'), ('K842977'), ('K860275'), ('K860635'), ('K864857'),
    ('K870128'), ('K873797'), ('K874619'), ('K874868'), ('K875156'), ('K896580'),
    ('K912593'), ('K913916'), ('K914343'), ('K914878'), ('K920430'), ('K921400'),
    ('K922621'), ('K932755'), ('K934353'), ('K960094'), ('K962541'), ('K963486'),
    ('K963509'), ('K970337'), ('K970351'), ('K973077'), ('K981847'), ('K982447'),
    ('K983834'), ('K990261'), ('K990309'), ('K990369'), ('K990666'), ('K991162'),
    ('K991485'), ('K991538'), ('K992153'), ('K992154'), ('K993874'), ('K994126'),
    ('K994146')
),
model AS (
  SELECT DISTINCT upper(p.value:identifier::string) AS k
  FROM (
    SELECT try_parse_json(extraction.result) AS r
    FROM bootcamp_students.doriel.fda_spike_extracted_v2
    WHERE k_number = 'K123598'
  ),
  LATERAL variant_explode(r:predicates) AS p
  WHERE p.value:identifier IS NOT NULL
)
SELECT 'only_in_model' AS side, m.k FROM model m LEFT ANTI JOIN ocr_truth o ON m.k = o.k
UNION ALL
SELECT 'only_in_ocr'   AS side, o.k FROM ocr_truth o LEFT ANTI JOIN model m ON m.k = o.k
ORDER BY side, k;
