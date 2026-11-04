-- Reference data that the platform needs to start (no inventory, no customers).
insert into public.organizations (code, name) values
  ('CESANTONI', 'CESANTONI'), ('ARMEX', 'ARMEX Logistics'), ('CLIENT', 'Customers')
on conflict (code) do nothing;

insert into public.warehouses (code, name, timezone) values ('HOUSTON', 'ARMEX Houston', 'America/Chicago')
on conflict (code) do nothing;

-- Finishes as written in the Houston inventory. English labels are PROPOSALS (verified = false)
-- until CESANTONI confirms them in the panel.
insert into public.finishes (code, name_es, name_en, verified) values
  ('MATE', 'Mate', 'Matte', false),
  ('GRIP', 'Grip', 'Grip', false),
  ('RIGATO', 'Rigato', 'Rigato', false),
  ('BRILLANTE', 'Brillante', 'Glossy', false),
  ('PULIDO BRILLANTE', 'Pulido brillante', 'Polished', false),
  ('PULIDO MATE', 'Pulido mate', 'Matte Polished', false),
  ('SATINADO', 'Satinado', 'Satin', false),
  ('VELVET FINISH', 'Velvet', 'Velvet', false),
  ('GLOW', 'Glow', 'Glow', false)
on conflict (code) do nothing;
