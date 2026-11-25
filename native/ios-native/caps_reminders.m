// reminders: the user's Reminders app.
//
// Not the same thing as `notify`, and the difference decides which one an agent
// should reach for. `notify` schedules a local notification: it fires once, it
// belongs to this app, and it leaves nothing behind — so "remind me in twenty
// minutes" needs no confirmation and no permission beyond notifications.
// Writing here puts a row in the user's own Reminders, which syncs to their
// other devices and may be a list they share with someone. That is their data,
// so every write stops for a confirmation, the same as the calendar's (§4.3).
//
// Reminders have no add-only tier and no system editor to borrow (EventKit's
// editor is events-only), so all three writes go through our own sheet.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "eventkit_shared.h"

static const NSUInteger kMaxReminders = 200;
static const NSUInteger kMaxNotesLength = 500;

static NSString *const kDeniedMessage =
  @"reminders access is off for this app. The user can turn it on in "
  @"Settings > Privacy & Security > Reminders. iOS only asks once, so it cannot be requested again from here";

static void with_access(void (^next)(BOOL granted, NSString *error)) {
  DshEventKitRequireAccess(EKEntityTypeReminder, NO, kDeniedMessage, next);
}

/// EKReminder keeps its due date as components, not a date.
static NSDate *due_date(EKReminder *reminder) {
  NSDateComponents *components = reminder.dueDateComponents;
  return components == nil ? nil : [NSCalendar.currentCalendar dateFromComponents:components];
}

static NSDateComponents *components_for(NSDate *date) {
  return [NSCalendar.currentCalendar
          components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                   | NSCalendarUnitHour | NSCalendarUnitMinute
            fromDate:date];
}

static NSString *truncated(NSString *text, NSUInteger limit) {
  if (text.length <= limit) return text;
  NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:limit];
  return [[text substringToIndex:range.location] stringByAppendingString:@"…"];
}

static NSDictionary *reminder_json(EKReminder *reminder) {
  NSMutableDictionary *entry = [@{
    @"id": reminder.calendarItemIdentifier ?: @"",
    @"title": reminder.title ?: @"",
    @"completed": @(reminder.completed),
    @"list": reminder.calendar.title ?: @"",
  } mutableCopy];
  NSDate *due = due_date(reminder);
  if (due != nil) entry[@"due"] = DshISO8601(due);
  if (reminder.notes.length > 0) entry[@"notes"] = truncated(reminder.notes, kMaxNotesLength);
  // 0 is "none"; 1-4 high, 5 medium, 6-9 low, as EventKit defines it.
  if (reminder.priority != 0) entry[@"priority"] = @(reminder.priority);
  // When it was ticked off, so "what did I finish this week" can be told apart
  // from what was finished years ago.
  if (reminder.completed && reminder.completionDate != nil) entry[@"completedAt"] = DshISO8601(reminder.completionDate);
  return entry;
}

/// Title and due date only: shown verbatim in a translated app, built natively
/// from the reminder as it is right now (§4.3.1).
/// 和 caps_calendar.m 的 event_summary 同理：要写进去的东西都得在框里看得见，
/// 用户才有得可判断。
static NSString *reminder_summary(EKReminder *reminder) {
  NSString *title = reminder.title.length > 0 ? reminder.title : @"(untitled)";
  NSMutableString *summary = [NSMutableString stringWithString:title];
  NSDate *due = due_date(reminder);
  if (due != nil) {
    NSString *iso = DshISO8601(due);
    [summary appendFormat:@"\n%@ %@", [iso substringToIndex:10], [iso substringWithRange:NSMakeRange(11, 5)]];
  }
  if (reminder.notes.length > 0) [summary appendFormat:@"\n%@", truncated(reminder.notes, 120)];
  return summary;
}

#pragma mark - Reading

/// A number argument, or nil when it is absent. Anything else is the caller's
/// mistake and is reported rather than silently ignored.
static BOOL number_arg(NSDictionary *args, NSString *key, NSNumber **out, NSString **error) {
  id value = args[key];
  if (value == nil || value == NSNull.null) { *out = nil; return YES; }
  if (![value isKindOfClass:NSNumber.class]) {
    *error = [NSString stringWithFormat:@"'%@' must be a number", key];
    return NO;
  }
  *out = value;
  return YES;
}

/// Seconds since 1970 as a date, or nil when absent.
static NSDate *date_arg(NSNumber *seconds) {
  return seconds == nil ? nil : [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
}

/// Whether `date` falls in [from, to). A missing date is outside every range.
static BOOL in_range(NSDate *date, NSDate *from, NSDate *to) {
  if (date == nil) return NO;
  if (from != nil && [date compare:from] == NSOrderedAscending) return NO;
  if (to != nil && [date compare:to] != NSOrderedAscending) return NO;
  return YES;
}

static void list_reminders(NSDictionary *args, DshNativeReply reply) {
  NSNumber *includeCompleted = args[@"includeCompleted"];
  BOOL wantCompleted = [includeCompleted isKindOfClass:NSNumber.class] && includeCompleted.boolValue;

  NSString *order = args[@"order"];
  if (order != nil && !([order isEqual:@"asc"] || [order isEqual:@"desc"])) {
    reply(nil, @"'order' must be \"asc\" or \"desc\"");
    return;
  }
  BOOL latestFirst = [order isEqual:@"desc"];
  NSString *sort = args[@"sort"];
  if (sort != nil && !([sort isEqual:@"due"] || [sort isEqual:@"completed"])) {
    reply(nil, @"'sort' must be \"due\" or \"completed\"");
    return;
  }
  BOOL byCompletion = [sort isEqual:@"completed"];

  NSNumber *from = nil, *to = nil, *completedFrom = nil, *completedTo = nil, *offsetArg = nil, *limitArg = nil;
  NSString *argError = nil;
  if (!number_arg(args, @"from", &from, &argError) || !number_arg(args, @"to", &to, &argError)
      || !number_arg(args, @"completedFrom", &completedFrom, &argError)
      || !number_arg(args, @"completedTo", &completedTo, &argError)
      || !number_arg(args, @"offset", &offsetArg, &argError) || !number_arg(args, @"limit", &limitArg, &argError)) {
    reply(nil, argError);
    return;
  }
  if (from != nil && to != nil && to.doubleValue <= from.doubleValue) {
    reply(nil, @"list needs 'to' to be after 'from'");
    return;
  }
  if (completedFrom != nil && completedTo != nil && completedTo.doubleValue <= completedFrom.doubleValue) {
    reply(nil, @"list needs 'completedTo' to be after 'completedFrom'");
    return;
  }
  NSDate *fromDate = date_arg(from), *toDate = date_arg(to);
  NSDate *completedFromDate = date_arg(completedFrom), *completedToDate = date_arg(completedTo);
  BOOL dueRange = fromDate != nil || toDate != nil;
  BOOL completionRange = completedFromDate != nil || completedToDate != nil;
  // Asking about when things were finished is asking about the finished ones:
  // an unfinished reminder has no completion date to sort or filter by.
  BOOL onlyCompleted = byCompletion || completionRange;
  NSUInteger offset = offsetArg == nil || offsetArg.doubleValue < 0 ? 0 : offsetArg.unsignedIntegerValue;
  // The page stays bounded whatever is asked for: the reply crosses into JS as
  // one JSON string, and the rest is a `nextOffset` away.
  NSUInteger limit = limitArg == nil || limitArg.doubleValue < 1 || limitArg.unsignedIntegerValue > kMaxReminders
    ? kMaxReminders : limitArg.unsignedIntegerValue;

  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      // Unfinished ones are what "what do I have to do" means; finished ones are
      // only asked for on purpose.
      NSPredicate *predicate = onlyCompleted
        ? [store predicateForCompletedRemindersWithCompletionDateStarting:nil ending:nil calendars:nil]
        : wantCompleted
          ? [store predicateForRemindersInCalendars:nil]
          : [store predicateForIncompleteRemindersWithDueDateStarting:nil ending:nil calendars:nil];
      // This fetch is already asynchronous, so it does not block the queue it
      // was asked on.
      [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *found) {
        if (found == nil) {
          reply(nil, @"the reminders could not be read");
          return;
        }
        // Ranges are applied here rather than in the predicate, so that they mean
        // the same whichever reminders were fetched. A reminder without the date
        // a range is about is outside it.
        NSArray<EKReminder *> *matching = found;
        if (dueRange || completionRange) {
          matching = [found filteredArrayUsingPredicate:
                      [NSPredicate predicateWithBlock:^BOOL(EKReminder *reminder, NSDictionary *bindings) {
            if (dueRange && !in_range(due_date(reminder), fromDate, toDate)) return NO;
            if (completionRange && !in_range(reminder.completionDate, completedFromDate, completedToDate)) return NO;
            return YES;
          }]];
        }
        NSArray<EKReminder *> *sorted = [matching sortedArrayUsingComparator:^NSComparisonResult(EKReminder *a, EKReminder *b) {
          NSDate *left = byCompletion ? a.completionDate : due_date(a);
          NSDate *right = byCompletion ? b.completionDate : due_date(b);
          // Ones without the date last in either order: a list that opens with
          // everything undated buries whatever is actually due.
          if (left == nil && right != nil) return NSOrderedDescending;
          if (left != nil && right == nil) return NSOrderedAscending;
          if (left != nil && right != nil) {
            NSComparisonResult byDate = latestFirst ? [right compare:left] : [left compare:right];
            if (byDate != NSOrderedSame) return byDate;
          }
          // Ties are settled by title and then id, so the order is the same on
          // every call and paging with `offset` neither skips nor repeats one.
          NSComparisonResult byTitle = [a.title ?: @"" compare:b.title ?: @""];
          if (byTitle != NSOrderedSame) return byTitle;
          return [a.calendarItemIdentifier ?: @"" compare:b.calendarItemIdentifier ?: @""];
        }];

        NSMutableArray *reminders = [NSMutableArray array];
        for (NSUInteger index = offset; index < sorted.count && reminders.count < limit; index++) {
          [reminders addObject:reminder_json(sorted[index])];
        }
        NSUInteger next = offset + reminders.count;
        NSMutableDictionary *result = [@{
          @"reminders": reminders,
          @"total": @(sorted.count),
          @"offset": @(offset),
          // (BOOL) for the same reason as caps_calendar.m: int 0/1 vs false.
          @"truncated": @((BOOL)(next < sorted.count)),
          @"auditSummary": [NSString stringWithFormat:@"· %lu", (unsigned long)sorted.count],
        } mutableCopy];
        if (next < sorted.count) result[@"nextOffset"] = @(next);
        reply(result, nil);
      }];
    });
  });
}

#pragma mark - Writing

static void create_reminder(NSDictionary *args, DshNativeReply reply) {
  NSString *title = args[@"title"];
  if (![title isKindOfClass:NSString.class] || title.length == 0) {
    reply(nil, @"create needs a non-empty 'title'");
    return;
  }
  NSNumber *dueSeconds = args[@"due"];
  if (dueSeconds != nil && ![dueSeconds isKindOfClass:NSNumber.class]) {
    reply(nil, @"'due' must be seconds since 1970");
    return;
  }

  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      EKReminder *reminder = [EKReminder reminderWithEventStore:store];
      reminder.title = title;
      reminder.calendar = store.defaultCalendarForNewReminders;
      NSString *notes = args[@"notes"];
      if ([notes isKindOfClass:NSString.class]) reminder.notes = notes;
      if (dueSeconds != nil) {
        NSDate *due = [NSDate dateWithTimeIntervalSince1970:dueSeconds.doubleValue];
        reminder.dueDateComponents = components_for(due);
        // A due date on its own is silent. Without an alarm the user is told
        // nothing when the time comes, which is not what they asked for.
        [reminder addAlarm:[EKAlarm alarmWithAbsoluteDate:due]];
      }
      if (reminder.calendar == nil) {
        reply(nil, @"this device has no list to put reminders in");
        return;
      }

      NSString *summary = reminder_summary(reminder);
      DshNativeConfirmWrite(@"reminders", @"create", summary, NO, ^(BOOL confirmed, NSString *refusal) {
        dispatch_async(DshEventKitQueue(), ^{
          if (refusal != nil) { reply(nil, refusal); return; }
          if (!confirmed) {
            reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
            return;
          }
          NSError *saveError = nil;
          if (![store saveReminder:reminder commit:YES error:&saveError]) {
            reply(nil, saveError.localizedDescription ?: @"the reminder could not be saved");
            return;
          }
          reply(@{@"action": DshNativeActionSaved, @"saved": @YES,
                  @"id": reminder.calendarItemIdentifier ?: @"",
                  @"auditSummary": summary}, nil);
        });
      });
    });
  });
}

/// Find the reminder an id names, then run `next` with it on the EventKit queue.
static void with_reminder(NSString *identifier, DshNativeReply reply,
                          void (^next)(EKEventStore *store, EKReminder *reminder)) {
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"this operation needs the reminder's 'id', as `list` returned it");
    return;
  }
  with_access(^(BOOL granted, NSString *error) {
    if (!granted) { reply(nil, error); return; }
    dispatch_async(DshEventKitQueue(), ^{
      EKEventStore *store = DshEventStore();
      EKCalendarItem *item = [store calendarItemWithIdentifier:identifier];
      if (![item isKindOfClass:EKReminder.class]) {
        reply(nil, @"no reminder with that id; it may have been deleted or the id may be stale");
        return;
      }
      next(store, (EKReminder *)item);
    });
  });
}

static void complete_reminder(NSDictionary *args, DshNativeReply reply) {

  with_reminder(args[@"id"], reply, ^(EKEventStore *store, EKReminder *reminder) {
    if (reminder.completed) {
      // Already done. Asking anyway trains the user to tap through sheets.
      reply(@{@"action": DshNativeActionCancelled, @"saved": @NO, @"unchanged": @YES}, nil);
      return;
    }
    NSString *summary = reminder_summary(reminder);
    DshNativeConfirmWrite(@"reminders", @"complete", summary, NO, ^(BOOL confirmed, NSString *refusal) {
      dispatch_async(DshEventKitQueue(), ^{
        if (refusal != nil) { reply(nil, refusal); return; }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"saved": @NO}, nil);
          return;
        }
        reminder.completed = YES;
        NSError *saveError = nil;
        if (![store saveReminder:reminder commit:YES error:&saveError]) {
          reply(nil, saveError.localizedDescription ?: @"the reminder could not be updated");
          return;
        }
        reply(@{@"action": DshNativeActionSaved, @"saved": @YES, @"auditSummary": summary}, nil);
      });
    });
  });
}

static void delete_reminder(NSDictionary *args, DshNativeReply reply) {

  with_reminder(args[@"id"], reply, ^(EKEventStore *store, EKReminder *reminder) {
    NSString *summary = reminder_summary(reminder);
    DshNativeConfirmWrite(@"reminders", @"delete", summary, YES, ^(BOOL confirmed, NSString *refusal) {
      dispatch_async(DshEventKitQueue(), ^{
        if (refusal != nil) { reply(nil, refusal); return; }
        if (!confirmed) {
          reply(@{@"action": DshNativeActionCancelled, @"deleted": @NO}, nil);
          return;
        }
        NSError *removeError = nil;
        if (![store removeReminder:reminder commit:YES error:&removeError]) {
          reply(nil, removeError.localizedDescription ?: @"the reminder could not be deleted");
          return;
        }
        reply(@{@"action": DshNativeActionDeleted, @"deleted": @YES, @"auditSummary": summary}, nil);
      });
    });
  });
}

void dsh_native_reminders(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) {
    list_reminders(args, reply);
  } else if ([op isEqualToString:@"create"]) {
    create_reminder(args, reply);
  } else if ([op isEqualToString:@"complete"]) {
    complete_reminder(args, reply);
  } else {
    delete_reminder(args, reply);
  }
}
