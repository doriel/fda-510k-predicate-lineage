-- Latest download attempt per K-number, with the PDF content when it succeeded.

select
    upper(trim(k_number))  as k_number,
    download_status,
    source_url,
    path,
    content,
    content_sha256,
    length                 as size_bytes,
    ingested_at
from {{ source('bronze', 'pdf_files') }}
qualify row_number() over (partition by upper(trim(k_number)) order by ingested_at desc) = 1