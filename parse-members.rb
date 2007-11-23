#!/usr/bin/env ruby
#
# Parsing all the data for members of the House of Representatives

require 'rubygems'
require 'mechanize'
require 'builder'
require 'rmagick'
require 'id'
require 'name'

# Links to the biographies of all *current* members
url = "http://parlinfoweb.aph.gov.au/piweb/browse.aspx?path=Parliamentary%20Handbook%20%3E%20Biographies%20%3E%20Current%20Members"
# Sizes of small thumbnail pictures of members
thumb_width = 44
thumb_height = 59

# Required to workaround long viewstates generated by .NET (whatever that means)
# See http://code.whytheluckystiff.net/hpricot/ticket/13
Hpricot.buffer_size = 262144

agent = WWW::Mechanize.new
page = agent.get(url)

xml = File.open('pwdata/members/all-members.xml', 'w')
x = Builder::XmlMarkup.new(:target => xml, :indent => 1)

x.instruct!

id_member = 1
id_person = 10001

members = []
page.links[29..-4].each do |link|
  throw "Should start with 'Biography for '" unless link.to_s =~ /^Biography for /
  name = Name.last_title_first(link.to_s[14..-1])

  puts "Processing: #{name.informal_name}"
  
  sub_page = agent.click(link)
  constituency = sub_page.search("#dlMetadata__ctl3_Label3").inner_html
	content = sub_page.search('div#contentstart')
  party = content.search("p")[1].inner_html
  if party == "Australian Labor Party"
    party = "Labor"
  elsif party == "Liberal Party of Australia"
    party = "Liberal"
  elsif party =~ /^The Nationals/
    party = "The Nationals"
  elsif party =~ /^Independent/
    party = "Independent"
  elsif party == "Country Liberal Party"
  else
    throw "Unknown party: #{party}"
  end
  # Grab image of member
  image_url = content.search("img").first.attributes['src']
  res = Net::HTTP.get_response(sub_page.uri + URI.parse(image_url))
  image = Magick::Image.from_blob(res.body)[0]
  big_image = image.resize_to_fit(thumb_width * 2, thumb_height * 2)
  small_image = image.resize_to_fit(thumb_width, thumb_height)
  big_image.write("/Library/WebServer/Documents/mysociety/twfy/www/docs/images/mpsL/#{id_person}.jpg")
  small_image.write("/Library/WebServer/Documents/mysociety/twfy/www/docs/images/mps/#{id_person}.jpg")

  members << {:id_member => id_member, :id_person => id_person, :house => "commons", :title => name.title, :firstname => name.first, :lastname => name.last,
    :constituency => constituency, :party => party, :fromdate => "2005-05-05", :todate => "9999-12-31",
    :fromwhy => "general_election", :towhy => "still_in_office"}
  id_member = id_member + 1
  id_person = id_person + 1
end

x.publicwhip do
  members.each do |member|
    id_member = "uk.org.publicwhip/member/#{member[:id_member]}"
    x.member(:id => id_member, :house => member[:house], :title => member[:title], :firstname => member[:firstname],
      :lastname => member[:lastname], :constituency => member[:constituency], :party => member[:party],
      :fromdate => member[:fromdate], :todate => member[:todate], :fromwhy => member[:fromwhy], :towhy => member[:towhy])
  end
end
xml.close

xml = File.open('pwdata/members/people.xml', 'w')
x = Builder::XmlMarkup.new(:target => xml, :indent => 1)
x.instruct!
x.publicwhip do
  members.each do |member|
    latestname = "#{member[:firstname]} #{member[:lastname]}"
    id_person = "uk.org.publicwhip/person/#{member[:id_person]}"
    id_member = "uk.org.publicwhip/member/#{member[:id_member]}"
    x.person(:id => id_person, :latestname => latestname) do
      x.office(:id => id_member, :current => "yes")
    end
  end
end
xml.close

# And load up the database
system("/Users/matthewl/twfy/cvs/mysociety/twfy/scripts/xml2db.pl --members --all --force")