-- crm_deals was empty in production while the CRM Kanban UI rendered
-- hardcoded demo cards instead of the (empty) live query result. Seed the
-- same narrative deals the UI used to hardcode, now as real rows, so
-- renderCRMKanban's live-data path has something to render and drag.
insert into public.crm_deals (title, company, contact_name, contact_email, value, stage, probability, close_date, notes)
values
  ('xPayments rollout', 'City of Mangaung', 'T. Molefe', 't.molefe@mangaung.gov.za', 4200000, 'qualified', 40, current_date + 45, 'Hot — budget approved'),
  ('Full stack platform', 'Buffalo City Metro', 'N. Zondo', 'n.zondo@buffalocity.gov.za', 2800000, 'qualified', 25, current_date + 60, 'Prospect, early stage'),
  ('xPayments + Billing bundle', 'Nelson Mandela Bay', 'S. Booysen', 's.booysen@mandelabay.gov.za', 5800000, 'proposal', 55, current_date + 30, 'Hot — proposal sent'),
  ('Platform renewal', 'Interfile Holdings', 'K. Adams', 'k.adams@interfile.co.za', 2400000, 'proposal', 60, current_date + 20, 'Warm — renewal in progress'),
  ('Full platform deployment', 'eThekwini Metro', 'P. Naidoo', 'p.naidoo@ethekwini.gov.za', 8400000, 'negotiation', 75, current_date + 14, 'Priority — final terms'),
  ('Platform upgrade', 'Ekurhuleni', 'L. Van Wyk', 'l.vanwyk@ekurhuleni.gov.za', 3200000, 'negotiation', 70, current_date + 10, 'Hot — upgrade scope'),
  ('Full ecosystem', 'City of Johannesburg', 'M. Khumalo', 'm.khumalo@joburg.org.za', 12400000, 'won', 100, current_date - 5, 'Closed won'),
  ('Full ecosystem', 'City of Tshwane', 'R. Pillay', 'r.pillay@tshwane.gov.za', 9800000, 'won', 100, current_date - 12, 'Closed won')
on conflict do nothing;
