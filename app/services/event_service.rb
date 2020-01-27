# frozen_string_literal: true

# Provides helper methods for Events resources and properties
class EventService
  def self.process_params(params)
    # handle dates & times (whole-day events or not, maybe during many days)
    range = EventService.date_range({ date: params[:start_date], time: params[:start_time] },
                                    { date: params[:end_date], time: params[:end_time] },
                                    params[:all_day] == 'true')
    params.merge!(availability_attributes: { id: params[:availability_id],
                                             start_at: range[:start_at],
                                             end_at: range[:end_at],
                                             available_type: 'event' })
          .except!(:start_date, :end_date, :start_time, :end_time, :all_day)
    # convert main price to centimes
    params[:amount] = (params[:amount].to_f * 100 if params[:amount].present?)
    # delete non-complete "other" prices and convert them to centimes
    unless params[:event_price_categories_attributes].nil?
      params[:event_price_categories_attributes].delete_if do |price_cat|
        price_cat[:price_category_id].empty? || price_cat[:amount].empty?
      end
      params[:event_price_categories_attributes].each do |price_cat|
        price_cat[:amount] = price_cat[:amount].to_f * 100
      end
    end
    # return the resulting params object
    params
  end

  def self.date_range(starting, ending, all_day)
    start_date = Time.zone.parse(starting[:date])
    end_date = Time.zone.parse(ending[:date])
    start_time = Time.parse(starting[:time]) if starting[:time]
    end_time = Time.parse(ending[:time]) if ending[:time]
    if all_day
      start_at = DateTime.new(start_date.year, start_date.month, start_date.day, 0, 0, 0, start_date.zone)
      end_at = DateTime.new(end_date.year, end_date.month, end_date.day, 23, 59, 59, end_date.zone)
    else
      start_at = DateTime.new(start_date.year, start_date.month, start_date.day, start_time.hour, start_time.min, start_time.sec, start_date.zone)
      end_at = DateTime.new(end_date.year, end_date.month, end_date.day, end_time.hour, end_time.min, end_time.sec, end_date.zone)
    end
    { start_at: start_at, end_at: end_at }
  end

  # delete one or more events (if periodic)
  def self.delete(event_id, mode = 'single')
    results = []
    event = Event.find(event_id)
    events = case mode
             when 'single'
               [event]
             when 'next'
               Event.includes(:availability)
                    .where(
                      'availabilities.start_at >= ? AND events.recurrence_id = ?',
                      event.availability.start_at,
                      event.recurrence_id
                    )
                    .references(:availabilities, :events)
             when 'all'
               Event.where(
                 'recurrence_id = ?',
                 event.recurrence_id
               )
             else
               []
             end

    events.each do |e|
      # here we use double negation because safe_destroy can return either a boolean (false) or an Availability (in case of delete success)
      results.push status: !!e.safe_destroy, event: e # rubocop:disable Style/DoubleNegation
    end
    results
  end

  # update one or more events (if periodic)
  def self.update(event, event_params, mode = 'single')
    results = []
    events = case mode
             when 'single'
               [event]
             when 'next'
               Event.includes(:availability)
                    .where(
                      'availabilities.start_at >= ? AND events.recurrence_id = ?',
                      event.availability.start_at,
                      event.recurrence_id
                    )
                    .references(:availabilities, :events)
             when 'all'
               Event.where(
                 'recurrence_id = ?',
                 event.recurrence_id
               )
             else
               []
             end

    events.each do |e|
      if e.id == event.id
        results.push status: !!e.update(event_params), event: e # rubocop:disable Style/DoubleNegation
      else
        puts '------------'
        puts e.id
        puts event_params
      end
    end
    results
  end
end
