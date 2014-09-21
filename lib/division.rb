require 'section'

class Division < Section
  def initialize(yes, no, yes_tellers, no_tellers, pairs, time, url, bill_url, count, division_count, date, house, logger = nil)
    @yes, @no, @yes_tellers, @no_tellers, @pairs, @division_count, @bill_url = yes, no, yes_tellers, no_tellers, pairs, division_count, bill_url
    super(time, url, count, date, house, logger)
  end

  # Quoting of url's is required to be nice and standards compliant
  def quoted_bill_url
    if @bill_url != nil
      @bill_url.gsub('&', '&amp;')
    end
  end

  def output(x)
    division_attributes = {:id => id, :nospeaker => "true", :divdate => @date, :divnumber => @division_count, :time => @time, :url => quoted_url}
    division_attributes[:bill_url] = quoted_bill_url if @bill_url != nil
    x.division(division_attributes) do
      count_attributes = {:ayes => @yes.size, :noes => @no.size,
        :tellerayes => @yes_tellers.size, :tellernoes => @no_tellers.size}
      count_attributes[:pairs] = @pairs.size if @pairs.size > 0
      x.divisioncount(count_attributes)
      output_vote_list(x, @yes, @yes_tellers, "aye")
      output_vote_list(x, @no, @no_tellers, "no")
      # Output pairs votes
      if @pairs.size > 0
        x.pairs do
          @pairs.each do |pair|
            x.pair do
              x.member({:id => pair.first.id}, pair.first.name.full_name)
              x.member({:id => pair.last.id}, pair.last.name.full_name)
            end
          end
        end
      end
    end
  end
  
  private

  def output_vote_list(x, members, tellers, vote)
    x.memberlist(:vote => vote) do
      members.each do |m|
        attributes = {:id => m.id, :vote => vote}
        attributes[:teller] = "yes" if tellers.include?(m)
        x.member(attributes, m.name.full_name)
      end
    end
  end
    
end