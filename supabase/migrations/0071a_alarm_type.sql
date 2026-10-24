-- Temperature / door / sensor alarms are their own kind of alert (people can choose how they get them)
alter type notify_type add value if not exists 'alarm';
