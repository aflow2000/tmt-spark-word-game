-- ============================================================
-- SPARK WORD — seed 040 · Issues
--
-- Mirrors the editions already on the TMT Spark site:
--   011 Concrete & Code (Jun 2026)   → STEEL   archived
--   012 Signal & Stream (Jul 2026)   → RADIO   archived
--   013 The Power Issue (Aug 2026)   → POWER   archived
--   014 The AI Infrastructure Race   → FIBER   ACTIVE  ← sample issue
--   015 (Oct 2026)                   → CLOUD   scheduled
-- Insert order matters: activating an issue archives the previous one.
-- ============================================================

insert into issues (issue_number, title, publication_date, answer, category, hint, explanation, status, newsletter_recipients) values
(11, 'Concrete & Code', '2026-06-04', 'STEEL', 'Construction',
 'The metal that frames data centers, fabs and towers — beams, columns, rebar — and the first line item tariffs move.',
 'Steel is the structural backbone of data centers, fabs and towers. Its price, tariff exposure and lead times move construction cost more than almost any other material, which is why cost managers track steel indices as closely as interest rates.',
 'archived', 3900),
(12, 'Signal & Stream', '2026-07-02', 'RADIO', 'Telecommunications',
 'The airwaves part of every mobile network — towers, antennas and the signal between them. AM, FM and 5G all use it.',
 'Radio access networks — the towers, antennas and small cells you can see — are the most visible and expensive part of a mobile network. Private 5G brings the same radio technology inside ports, factories and campuses, which is why connectivity is starting to appear in leases the way power does.',
 'archived', 4050),
(13, 'The Power Issue', '2026-08-06', 'POWER', 'Energy & Power',
 'Measured in megawatts and gigawatts — the one thing every new data center campus is short of. Plants make it, grids move it.',
 'Electricity has become the binding constraint on AI growth. Racks that drew 5–10 kW are now specified at 100 kW and beyond, campuses are planned in gigawatts, and interconnection queues in major markets stretch past four years — so site selection is an energy question first and a real estate question second.',
 'archived', 4180),
(14, 'The AI Infrastructure Race', '2026-09-03', 'FIBER', 'Telecommunications',
 'Strands of glass that carry data as pulses of light — the cable that connects a data center to the rest of the world.',
 'Fiber carries enormous volumes of digital information using light and is fundamental to telecom networks, data centers and modern digital infrastructure. Long-haul and metro fiber routes are now being built along the corridors connecting AI data center clusters — connectivity is following compute, and fiber access is becoming a site-selection criterion alongside power.',
 'active', 4250),
(15, 'Where Compute Lives', '2026-10-01', 'CLOUD', 'Digital Infrastructure',
 'Computing you rent by the hour from someone else''s data center — the business that made the hyperscalers giant.',
 'Cloud computing is capacity delivered as a service from someone else''s data centers. Cloud demand built the hyperscale industry over the last decade; AI is now building its second wave, with the largest cloud providers signing multi-gigawatt power deals and leasing capacity years ahead of delivery.',
 'scheduled', null)
on conflict (issue_number) do update set
  title = excluded.title, publication_date = excluded.publication_date, answer = excluded.answer,
  category = excluded.category, hint = excluded.hint, explanation = excluded.explanation,
  status = excluded.status, newsletter_recipients = excluded.newsletter_recipients;
