When 'I fill in "$phone_number" as my phone number' do |phone_number|
  fill_in 'user[phone_number]', :with => phone_number
end

When 'I press the sign up button' do
  click_button 'Sign up'
end

When 'I fill in my secret code' do
  fill_in 'user[secret_code]', :with => secret_code
end

When 'I fill in the date of birth with "$date_of_birth"' do |date_of_birth|
  fill_in 'user[dob]', :with => date_of_birth
end

When 'I fill in my name as "$name"' do |name|
  fill_in 'user[name]', :with => name
end

When 'I fill in my description as "$description"' do |description|
  fill_in 'user[description]', :with => description
end

When 'I check my gender as male' do
  check 'user[male]'
end

When 'I fill in the minimum age with "$min_age"' do |min_age|
  fill_in 'user[looking_for_minimum_age]', :with => min_age
end

When 'I fill in the maximum age with "$max_age"' do |max_age|
  fill_in 'user[looking_for_maximum_age]', :with => max_age
end

When 'I check my desired gender as female' do
  check 'user[looking_for_female]'
end

When 'I submit my profile' do
  click_button 'Get in there'
end

def secret_code
  nil # needs to pull it from a text message
end
