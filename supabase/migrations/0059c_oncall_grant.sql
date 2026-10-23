-- The office reads its on-call schedule directly (row security limits it to their own company)
grant select on oncall to authenticated;
