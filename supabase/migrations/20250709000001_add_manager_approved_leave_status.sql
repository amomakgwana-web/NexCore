-- Extend the leave_status enum with an intermediate stage so leave approval
-- can mirror the Claims SOP (manager review, then final HR/admin sign-off)
-- instead of a single approve/reject step.
alter type leave_status add value if not exists 'manager_approved';
