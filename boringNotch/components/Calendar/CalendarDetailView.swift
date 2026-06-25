//
//  CalendarDetailView.swift
//  boringNotch
//
//  Created by Claude Code
//

import Defaults
import SwiftUI

struct CalendarDetailView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var weatherManager = WeatherManager.shared
    @Default(.showWeatherInCalendar) var showWeatherInCalendar
    @State private var selectedDate = Date()
    @State private var currentMonth = Date()

    var body: some View {
        HStack(spacing: 0) {
            monthCalendarView
                .frame(maxWidth: .infinity)

            Divider()
                .background(Color.gray.opacity(0.3))

            dailyView
                .frame(maxWidth: .infinity)
        }
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, newState in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
            if newState == .open {
                weatherManager.refresh()
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
            weatherManager.refresh()
        }
    }

    private var monthCalendarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            monthYearHeader

            weekdayLabels

            calendarGrid

            Spacer()
        }
        .padding(12)
    }

    private var monthYearHeader: some View {
        HStack {
            Button(action: { previousMonth() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())

            Text(currentMonth.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Spacer()

            Button(action: { nextMonth() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                Text(day)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 4) {
            let weeks = getWeeksForMonth()
            ForEach(weeks, id: \.self) { week in
                HStack(spacing: 4) {
                    ForEach(week, id: \.self) { date in
                        if let date = date {
                            calendarDayButton(date: date)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func calendarDayButton(date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let isCurrentMonth = Calendar.current.isDate(date, equalTo: currentMonth, toGranularity: .month)
        let isToday = Calendar.current.isDateInToday(date)
        let dayWeather = showWeatherInCalendar && weatherManager.isInForecastRange(date)
            ? weatherManager.weather(for: date)
            : nil
        let textColor: Color = isSelected ? .white :
            isCurrentMonth ? .white.opacity(0.7) : .white.opacity(0.3)

        return Button(action: { selectedDate = date }) {
            VStack(spacing: 0) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(textColor)
                if let w = dayWeather {
                    Image(systemName: w.sfSymbolName)
                        .font(.system(size: 6))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : w.symbolColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: dayWeather != nil ? 30 : 24)
            .background(
                Group {
                    if isSelected {
                        Color.effectiveAccent
                            .cornerRadius(4)
                    } else if isToday {
                        Color.gray.opacity(0.2)
                            .cornerRadius(4)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var dailyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedDate.formatted(.dateTime.month(.wide).day().year()))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Spacer()
                    if showWeatherInCalendar,
                       let w = weatherManager.weather(for: selectedDate),
                       weatherManager.isInForecastRange(selectedDate) {
                        HStack(spacing: 3) {
                            Image(systemName: w.sfSymbolName)
                                .foregroundColor(w.symbolColor)
                            Text("\(weatherManager.formattedTemp(w.minTemp))–\(weatherManager.formattedTemp(w.maxTemp))")
                                .foregroundColor(.gray)
                        }
                        .font(.caption2)
                    }
                }

                if Calendar.current.isDateInToday(selectedDate) {
                    Text("Today")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Divider()
                .background(Color.gray.opacity(0.2))

            eventsListForSelectedDate

            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var eventsListForSelectedDate: some View {
        let filteredEvents = EventListView.filteredEvents(events: calendarManager.events)

        if filteredEvents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.headline)
                    .foregroundColor(.gray)
                Text("No events")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredEvents, id: \.id) { event in
                        eventRow(event: event)
                    }
                }
            }
        }
    }

    private func eventRow(event: EventModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: event.calendar.color))
                    .frame(width: 4, height: 4)

                Text(event.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            if !event.isAllDay {
                Text(formatEventTime(event: event))
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            } else {
                Text("All-day")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }

    private func formatEventTime(event: EventModel) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: event.start)) - \(formatter.string(from: event.end))"
    }

    private func previousMonth() {
        let calendar = Calendar.current
        if let newDate = calendar.date(byAdding: .month, value: -1, to: currentMonth) {
            currentMonth = newDate
        }
    }

    private func nextMonth() {
        let calendar = Calendar.current
        if let newDate = calendar.date(byAdding: .month, value: 1, to: currentMonth) {
            currentMonth = newDate
        }
    }

    private func getWeeksForMonth() -> [[Date?]] {
        let calendar = Calendar.current
        let range = calendar.range(of: .day, in: .month, for: currentMonth)!
        let numDays = range.count

        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1

        var weeks: [[Date?]] = []
        var currentWeek: [Date?] = Array(repeating: nil, count: firstWeekday)

        for day in 1...numDays {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                currentWeek.append(date)
                if currentWeek.count == 7 {
                    weeks.append(currentWeek)
                    currentWeek = []
                }
            }
        }

        if !currentWeek.isEmpty {
            while currentWeek.count < 7 {
                currentWeek.append(nil)
            }
            weeks.append(currentWeek)
        }

        return weeks
    }
}
