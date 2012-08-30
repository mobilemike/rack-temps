require 'rubygems'
require 'net/ssh'
require 'snmp'
require 'ruport'
require 'mail'
require 'pp'

include Ruport::Data

SERVERS =  [{fqdn: 'SERVERNAME', c: 1, u: 0, hw_class: :APC},
           {fqdn: 'SERVERNAME', c: 1, u: 7, hw_class: :G5, password: 'password'},
           {fqdn: 'SERVERNAME', c: 1, u: 8, hw_class: :G5, password: 'password'},
           {fqdn: 'SERVERNAME', c: 1, u: 9, hw_class: :G5, password: 'password'},
           {fqdn: 'SERVERNAME', c: 3, u: 1, hw_class: :G5, password: 'password'},
           {fqdn: 'SERVERNAME', c: 3, u: 2, hw_class: :G5, password: 'password'},
           {fqdn: 'SERVERNAME', c: 2, u: 9, hw_class: :Avamar, password: 'password'},
           {fqdn: 'SERVERNAME', c: 2, u: 8, hw_class: :Avamar, password: 'password'},
           {fqdn: 'SERVERNAME', c: 2, u: 7, hw_class: :Avamar, password: 'password'},
           {fqdn: 'SERVERNAME', c: 2, u: 6, hw_class: :Avamar, password: 'password'},
           {fqdn: 'SERVERNAME', c: 2, u: 4, hw_class: :Avamar, password: 'password'}]

@temps = []
@errors = String.new
start_time = Time.now

def query_apc server
  SNMP::Manager.open(Host: server[:fqdn], Version: :SNMPv1) do |apc|
    temp = Hash.new
    temp[:fqdn] = server[:fqdn]
    temp[:value] = apc.get_value('1.3.6.1.4.1.318.1.1.10.3.13.1.1.3.1').to_i
    @temps << temp
  end
end

def query_ilo_g5 server
  Net::SSH.start(server[:fqdn], 'Administrator', password: server[:password]) do |ilo|

    ilo.open_channel do |channel|

      channel.request_pty do |ch, success| 
        raise "Error requesting pty" unless success
      end

      channel.send_channel_request("shell") do |ch, success| 
        raise "Error opening shell" unless success
      end

      channel.exec 'show /system1/sensor4' do |ch, success| 
        raise "Error executing query" unless success
      end

      channel.on_data do |ch, data|
        if data[/ElementName=(.*)\r/, 1] == 'Ambient Zone'
          temp = Hash.new
          temp[:fqdn] = server[:fqdn]
          temp[:value] = case data[/RateUnits=(.*)\r/, 1]
            when "Celsius" then data[/CurrentReading=(.*)\r/, 1].to_f * (9.0/5) + 32
            else data[/CurrentReading=(.*)\r/, 1].to_f
          end
          @temps << temp
        end
      end
      
      ilo.loop
    end  
  end
end

def query_avamar server
  Net::SSH.start(server[:fqdn], 'root', password: server[:password]) do |om|

    om.exec! 'omreport chassis temps' do |ch, type, data|
      if data[/System Board Ambient Temp/]
        temp = Hash.new
        temp[:fqdn] = server[:fqdn]
        if data[/Reading.*(C)/]
          temp[:value] = data[/Reading.* (\d+\.?\d?)/, 1].to_f * (9.0/5) + 32
        else
          temp[:value] = data[/Reading.* (\d+\.?\d?)/, 1].to_f
        end
        @temps << temp
      end
    end
      
  end
end

SERVERS.each do |server|
  begin
    case server[:hw_class]
    when :G5 then query_ilo_g5 server
    when :Avamar then query_avamar server
    when :APC then query_apc server
    end
  rescue => e
    @errors << "#{server[:fqdn]} failed - #{e}"
  end
end

report = []
10.times {|a| report << Array.new(4)}

@temps.each do |temp|
  SERVERS.select {|server| server[:fqdn] == temp[:fqdn]}.each do |server|
    report[server[:u]][server[:c]] = temp[:value].round
  end
end

table = Table.new(data: report, 
                  column_names: ["C1", "C2", "C3", "C4"])
                  
all_temps = @temps.collect {|temp| temp[:value]}
average = all_temps.inject(0.0) { |sum, el| sum + el } / all_temps.size
max = all_temps.max
run_time = Time.now - start_time

puts table.to_s
puts "Avg: #{average.round 1}  |  Max: #{max}  |  Runtime #{run_time.round 1} secs"
puts @errors unless @errors.empty?

message = "<html><body><pre>"
message << table.to_s
message << "Avg: #{average.round 1}  |  Max: #{max}  |  Runtime #{run_time.round 1} secs"
message << @errors unless @errors.empty?
message << "</pre></body></html>"

message.gsub!("\n","<br />")

puts message
  
Mail.deliver do
  from            'SysOps Alerting Robot <robot@example.com>'
  to              'mobilemike@gmail.com'
  subject         'Data Room Cooling'
  content_type    'text/html; charset=UTF-8'
  body            message
  delivery_method :smtp, {address: 'mail.example.com'}
end