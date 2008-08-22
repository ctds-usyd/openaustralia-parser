require 'speech'
require 'mechanize_proxy'
require 'configuration'
require 'debates'
require 'builder_alpha_attributes'
require 'house'
require 'people_image_downloader'
# Using Active Support (part of Ruby on Rails) for Unicode support
require 'activesupport'

$KCODE = 'u'

class UnknownSpeaker
  def initialize(name)
    @name = name
  end
  
  def id
    "unknown"
  end
  
  def name
    Name.title_first_last(@name)
  end
end

require 'rubygems'
require 'log4r'

class HansardParser
  attr_reader :logger
  
  # people passed in initializer have to have their aph_id's set. This can be done by
  # calling PeopleImageDownloader.new.attach_aph_person_ids(people)
  def initialize(people)
    @people = people
    @conf = Configuration.new
    
    # Set up logging
    @logger = Log4r::Logger.new 'HansardParser'
    # Log to both standard out and the file set in configuration.yml
    @logger.add(Log4r::Outputter.stdout)
    @logger.add(Log4r::FileOutputter.new('foo', :filename => @conf.log_path, :trunc => false,
      :formatter => Log4r::PatternFormatter.new(:pattern => "[%l] %d :: %M")))
  end
  
  # Returns the subdirectory where html_cache files for a particular date are stored
  def cache_subdirectory(date, house)
    date.to_s
  end
  
  def page_in_proof?(page)
    proof = extract_metadata_tags(page)["Proof"]
    logger.error "Unexpected value '#{proof}' for metadata 'Proof'" unless proof == "Yes" || proof == "No"
    proof == "Yes"
  end
  
  # Returns true if any pages on the given date are at "proof" stage which means they might not be finalised
  def has_subpages_in_proof?(date, house)
    each_page_on_date(date, house) do |link, sub_page|
      return true if page_in_proof?(sub_page)
    end
    false
  end

  def each_page_on_date(date, house)
    url = "http://parlinfoweb.aph.gov.au/piweb/browse.aspx?path=Chamber%20%3E%20#{house.representatives? ? "House" : "Senate"}%20Hansard%20%3E%20#{date.year}%20%3E%20#{date.day}%20#{Date::MONTHNAMES[date.month]}%20#{date.year}"

    # Required to workaround long viewstates generated by .NET (whatever that means)
    # See http://code.whytheluckystiff.net/hpricot/ticket/13
    Hpricot.buffer_size = 1600000

    agent = MechanizeProxy.new
    agent.cache_subdirectory = cache_subdirectory(date, house)

    begin
      page = agent.get(url)
      # HACK: Don't know why if the page isn't found a return code isn't returned. So, hacking around this.
      if page.title == "ParlInfo Web - Error"
        throw "ParlInfo Web - Error"
      end
    rescue
      logger.warn "Could not retrieve overview page for date #{date}"
      return
    end
    # Structure of the page is such that we are only interested in some of the links
    page.links[30..-4].each do |link|
      begin
        sub_page = agent.click(link)
        @sub_page_permanent_url = extract_permanent_url(sub_page)

        yield link, sub_page
      rescue
        logger.error "Exception thrown during processing of sub page: #{@sub_page_permanent_url}"
        raise $!
      end
    end
  end
  
  def extract_permanent_url(page)
    page.links.text("[Permalink]").uri.to_s
  end
  
  # Parse but only if there is a page that is at "proof" stage
  def parse_date_house_only_in_proof(date, xml_filename, house)
    if has_subpages_in_proof?(date, house)
      logger.info "Deleting all cached html for #{date} because at least one sub page is in proof stage."
      FileUtils.rm_rf("#{@conf.html_cache_path}/#{cache_subdirectory(date, house)}")
      logger.info "Redownloading pages on #{date}..."
      parse_date_house(date, xml_filename, house)
    end
  end
  
  def parse_date_house(date, xml_filename, house)
    @logger.info "Parsing #{house} speeches for #{date.strftime('%a %d %b %Y')}..."    
    debates = Debates.new(date, house, @logger)
    
    content = false
    each_page_on_date(date, house) do |link, sub_page|
      content = true
      logger.warn "Page #{@sub_page_permanent_url} is in proof stage" if page_in_proof?(sub_page)
      parse_sub_day_page(link.to_s, sub_page, debates, date, house)
      # This ensures that every sub day page has a different major count which limits the impact
      # of when we start supporting things like written questions, procedurial text, etc..
      debates.increment_major_count      
    end
  
    # Only output the debate file if there's going to be something in it
    debates.output(xml_filename) if content
  end
  
  
  def parse_sub_day_page(link_text, sub_page, debates, date, house)
    # Only going to consider speeches for the time being
    if link_text =~ /^Speech:/ || link_text =~ /^QUESTIONS? WITHOUT NOTICE/i || link_text =~ /^QUESTIONS TO THE SPEAKER:/
      # Link text for speech has format:
      # HEADING > NAME > HOUR:MINS:SECS
      time = link_text.split('>')[2]
      time.strip! unless time.nil?
      # Check that time is something valid
      unless time =~ /^\d\d:\d\d:\d\d$/
        logger.error "Time #{time} invalid on link #{link_text}"
        time = nil
      end
      parse_sub_day_speech_page(sub_page, time, debates, date, house)
    #elsif link_text =~ /^Procedural text:/
    #  # Assuming no time recorded for Procedural text
    #  parse_sub_day_speech_page(sub_page, nil, debates, date)
    elsif link_text == "Official Hansard" || link_text =~ /^Start of Business/ || link_text == "Adjournment"
      # Do nothing - skip this entirely
    elsif link_text =~ /^Procedural text:/ || link_text =~ /^QUESTIONS IN WRITING:/ || link_text =~ /^Division:/ ||
        link_text =~ /^REQUESTS? FOR DETAILED INFORMATION:/ ||
        link_text =~ /^Petition:/ || link_text =~ /^PRIVILEGE:/ || link_text == "Interruption" ||
        link_text =~ /^QUESTIONS? ON NOTICE:/i || link_text =~ /^QUESTIONS TO THE SPEAKER/
      #logger.info "Not yet supporting: #{link_text}"
    # Hack to deal with incorrectly titled page on 31 Oct 2005 
    elsif link_text =~ /^IRAQ/
      #logger.info "Not yet supporting: #{link_text}"
    else
      throw "Unsupported: #{link_text}"
    end
  end

  # Given a sub-page extract a hash of all the metadata tags and values
  def extract_metadata_tags(page)
    # Extract metadata tags
    i = 0
    metadata = {}
    while true
      label_tag = page.search("span#dlMetadata__ctl#{i}_Label2").first
      value_tag = page.search("span#dlMetadata__ctl#{i}_Label3").first
      break if label_tag.nil? && value_tag.nil?
      metadata[label_tag.inner_text] = value_tag.inner_text.strip
      i = i + 1
    end
    metadata
  end

  def parse_sub_day_speech_page(sub_page, time, debates, date, house)
    top_content_tag = sub_page.search('div#contentstart').first
    throw "Page on date #{date} at time #{time} has no content" if top_content_tag.nil?
    
    newtitle = sub_page.search('div#contentstart div.hansardtitle').map { |m| m.inner_html }.join('; ')
    newsubtitle = sub_page.search('div#contentstart div.hansardsubtitle').map { |m| m.inner_html }.join('; ')

    debates.add_heading(newtitle, newsubtitle, @sub_page_permanent_url)

    speaker = nil
    top_content_tag.children.each do |e|
      break unless e.respond_to?(:attributes)
      
      class_value = e.attributes["class"]
      if e.name == "div"
        if class_value == "hansardtitlegroup" || class_value == "hansardsubtitlegroup"
        elsif class_value == "speech0" || class_value == "speech1"
          e.children[1..-1].each do |e|
            speaker = parse_speech_block(e, speaker, time, @sub_page_permanent_url, debates, date, house)
            debates.increment_minor_count
          end
        elsif class_value == "motionnospeech" || class_value == "subspeech0" || class_value == "subspeech1" ||
            class_value == "motion" || class_value = "quote"
          speaker = parse_speech_block(e, speaker, time, @sub_page_permanent_url, debates, date, house)
          debates.increment_minor_count
        else
          throw "Unexpected class value #{class_value} for tag #{e.name}"
        end
      elsif e.name == "p"
        speaker = parse_speech_block(e, speaker, time, @sub_page_permanent_url, debates, date, house)
        debates.increment_minor_count
      elsif e.name == "table"
        if class_value == "division"
          debates.increment_minor_count
          # Ignore (for the time being)
        else
          throw "Unexpected class value #{class_value} for tag #{e.name}"
        end
      else
        throw "Unexpected tag #{e.name}"
      end
    end
  end
  
  # Returns new speaker
  def parse_speech_block(e, speaker, time, url, debates, date, house)
    speakername, speaker_url, interjection = extract_speakername(e, house)
    # Only change speaker if a speaker name or url was found
    this_speaker = (speakername || speaker_url) ? lookup_speaker(speakername, speaker_url, date, house) : speaker
    debates.add_speech(this_speaker, time, url, clean_speech_content(url, e, house), @sub_page_permanent_url)
    # With interjections the next speech should never be by the person doing the interjection
    if interjection
      speaker
    else
      this_speaker
    end
  end
  
  def extract_speakername(content, house)
    interjection = false
    speaker_url = nil
    # Try to extract speaker name from talkername tag
    tag = content.search('span.talkername a').first
    tag2 = content.search('span.speechname').first
    if tag
      name = tag.inner_html
      speaker_url = tag.attributes['href']
      # Now check if there is something like <span class="talkername"><a>Some Text</a></span> <b>(Some Text)</b>
      tag = content.search('span.talkername ~ b').first
      # Only use it if it is surrounded by brackets
      if tag && tag.inner_html.match(/\((.*)\)/)
        name += " " + $~[0]
      end
    elsif tag2
      name = tag2.inner_html
    # If that fails try an interjection
    elsif content.search("div.speechType").inner_html == "Interjection"
      interjection = true
      text = strip_tags(content.search("div.speechType + *").first)
      m = text.match(/([a-z].*) interjecting/i)
      if m
        name = m[1]
        talker_not_correctly_marked_up = true
      else
        m = text.match(/([a-z].*)—/i)
        if m
          name = m[1]
          talker_not_correctly_marked_up = true
        else
          name = nil
        end
      end
    # As a last resort try searching for interjection text
    else
      m = strip_tags(content).match(/([a-z].*) interjecting/i)
      if m
        name = m[1]
        talker_not_correctly_marked_up = true
        interjection = true
      else
        m = strip_tags(content).match(/^([a-z].*?)—/i)
        if m and generic_speaker?(m[1], house)
          name = m[1]
          talker_not_correctly_marked_up = true
        end
      end
    end
    
    if talker_not_correctly_marked_up
      logger.warn "Speech by #{name} not specified by talkername in #{@sub_page_permanent_url}" unless generic_speaker?(name, house)
    end
    [name, speaker_url, interjection]
  end
  
  def clean_speech_content(base_url, content, house)
    doc = Hpricot(content.to_s)
    talkername_tags = doc.search('span.talkername ~ b ~ *')
    talkername_tags.each do |tag|
      if tag.to_s.chars[0..0] == '—'
        tag.swap(tag.to_s.chars[1..-1])
      end
    end
    talkername_tags = doc.search('span.talkername ~ *')
    talkername_tags.each do |tag|
      if tag.to_s.chars[0..0] == '—'
        tag.swap(tag.to_s.chars[1..-1])
      end
    end
    doc = remove_generic_speaker_names(doc, house)
    doc.search('div.speechType').remove
    doc.search('span.talkername ~ b').remove
    doc.search('span.talkername').remove
    doc.search('span.talkerelectorate').remove
    doc.search('span.talkerrole').remove
    doc.search('hr').remove
    make_motions_and_quotes_italic(doc)
    remove_subspeech_tags(doc)
    fix_links(base_url, doc)
    make_amendments_italic(doc)
    fix_attributes_of_p_tags(doc)
    fix_attributes_of_td_tags(doc)
    fix_motionnospeech_tags(doc)
    # Do pure string manipulations from here
    text = doc.to_s.chars.normalize(:c)
    text = text.gsub(/\(\d{1,2}.\d\d (a|p).m.\)—/, '')
    text = text.gsub('()', '')
    text = text.gsub('<div class="separator"></div>', '')
    # Look for tags in the text and display warnings if any of them aren't being handled yet
    text.scan(/<[a-z][^>]*>/i) do |t|
      m = t.match(/<([a-z]*) [^>]*>/i)
      if m
        tag = m[1]
      else
        tag = t[1..-2]
      end
      allowed_tags = ["b", "i", "dl", "dt", "dd", "ul", "li", "a", "table", "td", "tr", "img"]
      if !allowed_tags.include?(tag) && t != "<p>" && t != '<p class="italic">'
        logger.error "Tag #{t} is present in speech contents: #{text} on #{@sub_page_permanent_url}"
      end
    end
    # Reparse
    doc = Hpricot(text)
    doc.traverse_element do |node|
      text = node.to_s.chars
      if text[0..0] == '—' || text[0..0] == [160].pack('U*')
        node.swap(text[1..-1].to_s)
      end
    end
    doc
  end
  
  def remove_generic_speaker_names(content, house)
    name, speaker_url, interjection = extract_speakername(content, house)
    if generic_speaker?(name, house) and !interjection
      #remove everything before the first hyphen
      return Hpricot(content.to_s.gsub!(/^<p[^>]*>.*?—/i, "<p>"))
    end
    
    return content
  end
  
  def fix_motionnospeech_tags(content)
    content.search('div.motionnospeech').wrap('<p></p>')
    replace_with_inner_html(content, 'div.motionnospeech')
    content.search('span.speechname').remove
    content.search('span.speechelectorate').remove
    content.search('span.speechrole').remove
    content.search('span.speechtime').remove
  end
  
  def fix_attributes_of_p_tags(content)
    content.search('p.parabold').wrap('<b></b>')
    content.search('p').each do |e|
      class_value = e.get_attribute('class')
      if class_value == "block" || class_value == "parablock" || class_value == "parasmalltablejustified" ||
          class_value == "parasmalltableleft" || class_value == "parabold" || class_value == "paraheading" || class_value == "paracentre"
        e.remove_attribute('class')
      elsif class_value == "paraitalic"
        e.set_attribute('class', 'italic')
      elsif class_value == "italic" && e.get_attribute('style')
        e.remove_attribute('style')
      end
      e.remove_attribute('style')
    end
  end
  
  def fix_attributes_of_td_tags(content)
    content.search('td').each do |e|
      e.remove_attribute('style')
    end
  end
  
  def fix_links(base_url, content)
    content.search('a').each do |e|
      href_value = e.get_attribute('href')
      if href_value.nil?
        # Remove a tags
        e.swap(e.inner_html)
      else
        e.set_attribute('href', URI.join(base_url, href_value))
      end
    end
    content.search('img').each do |e|
      e.set_attribute('src', URI.join(base_url, e.get_attribute('src')))
    end
    content
  end
  
  def replace_with_inner_html(content, search)
    content.search(search).each do |e|
      e.swap(e.inner_html)
    end
  end
  
  def make_motions_and_quotes_italic(content)
    content.search('div.motion p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.motion')
    content.search('div.quote p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.quote')
    content
  end
  
  def make_amendments_italic(content)
    content.search('div.amendments div.amendment0 p').set(:class => 'italic')
    content.search('div.amendments div.amendment1 p').set(:class => 'italic')
    replace_with_inner_html(content, 'div.amendment0')
    replace_with_inner_html(content, 'div.amendment1')
    replace_with_inner_html(content, 'div.amendments')
    content
  end
  
  def remove_subspeech_tags(content)
    replace_with_inner_html(content, 'div.subspeech0')
    replace_with_inner_html(content, 'div.subspeech1')
    content
  end
  
  def lookup_speaker_by_title(speakername, date, house)
    # Some sanity checking.
    if speakername =~ /speaker/i && house.senate?
      logger.error "The Speaker is not expected in the Senate on #{@sub_page_permanent_url}"
      return nil
    elsif speakername =~ /president/i && house.representatives?
      logger.error "The President is not expected in the House of Representatives on #{@sub_page_permanent_url}"
      return nil
    elsif speakername =~ /chairman/i && house.representatives?
      logger.error "The Chairman is not expected in the House of Representatives on #{@sub_page_permanent_url}"
      return nil
    end
    
    # Handle speakers where they are referred to by position rather than name
    if speakername =~ /^the speaker/i
      @people.house_speaker(date)
    elsif speakername =~ /^the deputy speaker/i
      @people.deputy_house_speaker(date)
    elsif speakername =~ /^the president/i
      @people.senate_president(date)
    elsif speakername =~ /^(the )?chairman/i || speakername =~ /^the deputy president/i
      # The "Chairman" in the main Senate Hansard is when the Senate is sitting as a committee of the whole Senate.
      # In this case, the "Chairman" is the deputy president. See http://www.aph.gov.au/senate/pubs/briefs/brief06.htm#3
      @people.deputy_senate_president(date)
    # Handle names in brackets
    elsif speakername =~ /^the (deputy speaker|acting deputy president|temporary chairman) \((.*)\)/i
      @people.find_member_by_name_current_on_date(Name.title_first_last($~[2]), date, house)
    end
  end
  
  def is_speaker?(speakertitle, date, house)
    lookup_speaker_by_title(speakertitle, date, house)
  end
  
  def lookup_speaker_by_name(speakername, date, house)
    throw "speakername can not be nil in lookup_speaker" if speakername.nil?
    
    member = lookup_speaker_by_title(speakername, date, house)    
    # If member hasn't already been set then lookup using speakername
    if member.nil?
      name = Name.title_first_last(speakername)
      member = @people.find_member_by_name_current_on_date(name, date, house)
    end
    member
  end
  
  def lookup_speaker_by_url(speaker_url, date, house)
    if speaker_url =~ /^view_document.aspx\?TABLE=biogs&ID=(\d+)$/
      person = @people.find_person_by_aph_id($~[1].to_i)
      if person
        # Now find the member for that person who is current on the given date
        @people.find_member_by_name_current_on_date(person.name, date, house)
      else
        logger.error "Can't figure out which person the link #{speaker_url} belongs to on #{@sub_page_permanent_url}"
        nil
      end
    elsif speaker_url.nil? || speaker_url == "view_document.aspx?TABLE=biogs&ID="
      nil
    else
      logger.error "Speaker link has unexpected format: #{speaker_url} on #{@sub_page_permanent_url}"
      nil
    end
  end
  
  def lookup_speaker(speakername, speaker_url, date, house)
    member_name = lookup_speaker_by_name(speakername, date, house)
    if member_name
      member = member_name
    else
      # Only try to use the link if we can't look up by name
      member_url = lookup_speaker_by_url(speaker_url, date, house)
      if member_url
        # If link is valid use that to look up the member
        member = member_url
        logger.error "Determined speaker #{member.person.name.full_name} by link only on #{@sub_page_permanent_url}. Valid name missing."
      else
        member = nil
      end
    end
    
    if member.nil?
      logger.warn "Unknown speaker #{speakername} in #{@sub_page_permanent_url}" unless generic_speaker?(speakername, house)
      member = UnknownSpeaker.new(speakername)
    end
    member
  end
  
  def generic_speaker?(speakername, house)
    if house.representatives?
      speakername =~ /^(an? )?(honourable|opposition|government) members?$/i
    else
      speakername =~ /^(an? )?(honourable|opposition|government) senators?$/i
    end
  end

  def strip_tags(doc)
    str=doc.to_s
    str.gsub(/<\/?[^>]*>/, "")
  end

  def min(a, b)
    if a < b
      a
    else
      b
    end
  end
end
