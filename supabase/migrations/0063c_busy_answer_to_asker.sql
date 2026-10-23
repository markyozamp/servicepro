-- The person who asked to come during busy hours (often the tech) hears the answer too, not just their office.
-- Same alert key as the office's, so nobody gets it twice.
select from _patch_fn('store_allow_busy(uuid)'::regprocedure,
  '  perform _notify_office(p_wo, ''new_call'', format(''Call #%s: %s at the location says you can come during their busy hours.'', w.number, m.full_name), ''busyok:'' || p_wo);',
  '  perform _notify_office(p_wo, ''new_call'', format(''Call #%s: %s at the location says you can come during their busy hours.'', w.number, m.full_name), ''busyok:'' || p_wo);
  perform _notify(w.busy_ask_by, p_wo, ''new_call'', format(''Call #%s: %s at the location says you can come during their busy hours.'', w.number, m.full_name), ''busyok:'' || p_wo);');

select from _patch_fn('store_decline_busy(uuid, text)'::regprocedure,
  '    ''busyno:'' || p_wo || '':'' || extract(epoch from now())::bigint);',
  '    ''busyno:'' || p_wo || '':'' || extract(epoch from now())::bigint);
  perform _notify(w.busy_ask_by, p_wo, ''new_call'', format(''Call #%s: %s at the location says not during their busy hours%s. Come after: %s.'',
    w.number, m.full_name, coalesce('' ('' || nullif(trim(p_note), '''') || '')'', ''''), coalesce(_busy_summary(w.site_id), ''their busy hours'')),
    ''busyno:'' || p_wo || '':'' || extract(epoch from now())::bigint);');
