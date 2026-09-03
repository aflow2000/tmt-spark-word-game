-- ============================================================
-- SPARK WORD — seed 050 · Test subscribers
--
-- Illustrative people at illustrative companies (matching the site's
-- proof-of-concept tone). Tokens are FIXED so the README can list
-- working test links; production tokens are random (sw_new_token()).
-- Delete this data before go-live:  delete from subscribers where notes = 'seed';
-- ============================================================

insert into subscribers (email, first_name, last_name, company, subscriber_token, newsletter_subscriber, leaderboard_visibility, source, notes) values
('sarah.m@example-nvidia.com',      'Sarah',    'Mitchell',  'NVIDIA',              'test-sarah-mitchell-nvidia-00000000000001', true,  'first_last_initial', 'newsletter_import', 'seed'),
('david.l@example-nvidia.com',      'David',    'Lin',       'NVIDIA',              'test-david-lin-nvidia-000000000000000002', true,  'first_last_initial', 'newsletter_import', 'seed'),
('priya.n@example-nvidia.com',      'Priya',    'Natarajan', 'NVIDIA',              'test-priya-natarajan-nvidia-000000000003', true,  'full_name',          'newsletter_import', 'seed'),
('james.r@example-tt.com',          'James',    'Reyes',     'Turner & Townsend',   'test-james-reyes-tt-00000000000000000004', true,  'first_last_initial', 'newsletter_import', 'seed'),
('alex.c@example-tt.com',           'Alex',     'Cortessis', 'Turner & Townsend',   'test-alex-cortessis-tt-000000000000000005', true,  'first_last_initial', 'newsletter_import', 'seed'),
('mei.t@example-tt.com',            'Mei',      'Tanaka',    'Turner & Townsend',   'test-mei-tanaka-tt-000000000000000000006', true,  'anonymous',          'newsletter_import', 'seed'),
('omar.h@example-tt.com',           'Omar',     'Haddad',    'Turner & Townsend',   'test-omar-haddad-tt-00000000000000000007', true,  'first_last_initial', 'newsletter_import', 'seed'),
('michelle.k@example-google.com',   'Michelle', 'Kim',       'Google',              'test-michelle-kim-google-0000000000000008', true,  'first_last_initial', 'newsletter_import', 'seed'),
('tom.b@example-google.com',        'Tom',      'Baker',     'Google',              'test-tom-baker-google-000000000000000009', true,  'first_last_initial', 'newsletter_import', 'seed'),
('ana.s@example-google.com',        'Ana',      'Silva',     'Google',              'test-ana-silva-google-000000000000000010', true,  'first_last_initial', 'newsletter_import', 'seed'),
('chris.w@example-microsoft.com',   'Chris',    'Walsh',     'Microsoft',           'test-chris-walsh-microsoft-00000000000011', true,  'first_last_initial', 'newsletter_import', 'seed'),
('dana.o@example-microsoft.com',    'Dana',     'Okafor',    'Microsoft',           'test-dana-okafor-microsoft-00000000000012', true,  'first_last_initial', 'newsletter_import', 'seed'),
('luis.f@example-microsoft.com',    'Luis',     'Fernandez', 'Microsoft Corp.',     'test-luis-fernandez-microsoft-0000000013', true,  'first_last_initial', 'newsletter_import', 'seed'),
('grace.p@example-meta.com',        'Grace',    'Park',      'Meta',                'test-grace-park-meta-0000000000000000014', true,  'first_last_initial', 'newsletter_import', 'seed'),
('ben.a@example-meta.com',          'Ben',      'Adler',     'Meta',                'test-ben-adler-meta-00000000000000000015', true,  'first_last_initial', 'newsletter_import', 'seed'),
('nadia.r@example-vantage.com',     'Nadia',    'Rahman',    'Vantage Data Centers','test-nadia-rahman-vantage-000000000000016', true,  'first_last_initial', 'newsletter_import', 'seed'),
('new.reader@example.com',          'Jordan',   'Lee',       'Digital Realty',      'test-jordan-lee-never-played-00000000017', true,  'first_last_initial', 'newsletter_import', 'seed')
on conflict (email) do update set
  first_name = excluded.first_name, last_name = excluded.last_name, company = excluded.company,
  subscriber_token = excluded.subscriber_token, leaderboard_visibility = excluded.leaderboard_visibility, notes = 'seed';
