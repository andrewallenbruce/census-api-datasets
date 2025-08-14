# Compare endpoints metadata saved in repo vs the latest
# Save new data if there are changes

# Uses the censusapi listCensusApis() function to extract and format 
# meaningful fields from full metadata at https://api.census.gov/data.json

library(censusapi)

source("scripts/update-settings.R")

################################################################
# Function to pass variables between R and Github Actions
# GITHUB_ENV is used within a job
# Also need to send to GITHUB_OUTPUT if using the var in 
# future jobs - building the site and posting to Bluesky
################################################################
send_var <- function(var_name,
										 var_value,
										 destination) {
	send_part <- paste0('"', var_name, "=", var_value, '"', ' >> "$', destination, '"')
	print(send_part)
	system(paste('echo', send_part))
}
send_env <- function(var_name,
										 var_value,
										 send_output = FALSE) {
	
	send_var(var_name, var_value, "GITHUB_ENV")
	
	# Save to Github output for use in future jobs
	if (send_output == TRUE) {
		send_var(var_name, var_value, "GITHUB_OUTPUT")
	}
}

################################################################
# Basic info
################################################################
# Read in old metadata
endpoints_old <- read.csv("src/routes/_data/endpoints.csv")
endpoints_old[endpoints_old == ""] <- NA 

# Get metadata
endpoints_new <- listCensusApis()

# Sort (using base R to avoid extra dependencies)
endpoints_new <- endpoints_new[order(endpoints_new$vintage, endpoints_new$name, decreasing = T),]
row.names(endpoints_new) <- NULL

# Time of data checking for commit message and data saving
current_time <- as.POSIXct(Sys.time(),
													 tz = "America/New_York")
string_time <- format(current_time, "%Y-%m-%d %H:%M")

################################################################
# Tests for these functions when the data has not ACTUALLY changed
# Variable test_changes imported from test-data-changes.R
################################################################
if (data_test == T) {
	# system('echo "DATA_TEST=true" >> "$GITHUB_ENV"')
	test_message <- "TEST"
	
	# How many rows to add or remove
	add_num <- sample(1:5, 1)
	rm_num <- sample(1:5, 1)
	
	# Change a less-important metadata field
	endpoints_new[1,1] <- "test minor"
	
	# Fake remove rows
	rm_rows <- sample(1:nrow(endpoints_new), rm_num, replace=FALSE)
	for (f in seq_along(rm_rows)) {
		endpoints_new <- endpoints_new[-rm_rows[f],]
	}
	
	# Fake new rows
	add_rows <- sample(1:nrow(endpoints_new), add_num, replace=FALSE)
	for (f in (1:add_num)) {
		fake_row <- endpoints_old[add_rows[f],]
		fake_row$name <- paste0(fake_row$name, "/test")
		fake_row$title <- paste("TEST", fake_row$title)
		fake_row$url <- paste0(fake_row$url, "/fake")
		endpoints_new <- rbind(fake_row, endpoints_new)
	}
} else {
	# system('echo "DATA_TEST=false" >> "$GITHUB_ENV"')	
	test_message <- ""
}

################################################################
# Is there any difference between old and new data?
################################################################
updated_data <- identical(endpoints_old, endpoints_new)
print("Are the old and new endpoints metadata identical?")
print(updated_data)

if (updated_data == T) {
	data_change <- "None"
	# system('echo "UPDATED_DATA=false" >> "$GITHUB_ENV"')
	commit_message <- "No data changes"
	urls_added <- NULL
	urls_removed <- NULL
	
} else {
	# If there is a difference, see if there are added and/or removed endpoints
	
	# If the endpoint row changed in some other way like updated
	# description or temporal field I'm less interested in the details
	# save in the git diff but not too important for this project
	
	urls_new <- endpoints_new$url
	urls_old <- endpoints_old$url	

	urls_added <- setdiff(urls_new, urls_old)
	urls_removed <- setdiff(urls_old, urls_new)
	
	if (length(urls_added) > 0 | (length(urls_removed) > 0)) {
		data_change <- "Major"
		# Extract the full removed or added rows
		
		if (length(urls_added) > 0) {
			print(paste("Endpoint added: ", urls_added))
			rows_added <- endpoints_new[(endpoints_new$url %in% urls_added),]
			rows_added$change <- "Added"
		}
		
		if (length(urls_removed) > 0) {
			print(paste("Endpoint removed: ", urls_removed))
			rows_removed <- endpoints_old[(endpoints_old$url %in% urls_removed),]
			rows_removed$change <- "Removed"
		}
		
		# Construct a df with changes
		if (length(urls_added) > 0 & length(urls_removed) == 0) {
			rows_noted <- rows_added
		}	else if (length(urls_added) == 0 & length(urls_removed) > 0) {
			rows_noted <- rows_removed
		}  else {
			rows_noted <- rbind(rows_added, rows_removed)
		}
		
		rows_noted$change_date <- string_time
		rows_noted <- rows_noted[ , c("change",
														names(rows_noted)[names(rows_noted) != "change"])]
		rows_noted <- rows_noted[ , c("change_date",
																	names(rows_noted)[names(rows_noted) != "change_date"])]
		
		# Append existing file of endpoint additions/deletions
		endpoint_changes <- read.csv("src/routes/_data/endpoint-changes.csv")
		endpoint_changes <- rbind(endpoint_changes, rows_noted)
		write.csv(endpoint_changes, "src/routes/_data/endpoint-changes.csv", na = "", row.names = F)
		
		commit_message <- "Major data update"
		
	} else {
		data_change <- "Minor"
		commit_message <- "Minor data update"
	}
	
	# Update the minimal csv
	print("Updating data/endpoints.csv'")
	write.csv(endpoints_new, "src/routes/_data/endpoints.csv", row.names = F, na = "")
	
	# Download full metadata
	print("Updating full data/data.json")
	download.file("https://api.census.gov/data.json", destfile = "data/data.json")
	
	# Save out the update status to Github actions env
	# system('echo "UPDATED_DATA=true" >> "$GITHUB_ENV"')
}

################################################################
# Save out results to logs and prep for commit
################################################################

# Update timestamp for page
update_json <- paste0('{"updated": "', current_time, '"}')
writeLines(update_json, "src/routes/_data/update-time.json")

# Save log of update results
update_results <- read.csv("data/update-log.csv")
update_new <- data.frame(
	date = string_time,
	test_data = data_test,
	test_revert = test_revert,
	change = commit_message,
	endpoints_total = nrow(endpoints_new),
	endpoints_added = length(urls_added),
	urls_added = toString(urls_added),
	endpoints_removed = length(urls_removed),
	urls_removed = toString(urls_removed)
)

update_results <- rbind(update_new, update_results)
write.csv(update_results, "data/update-log.csv", row.names = F, na = "")

# Prepare commit message
commit_text <- paste(string_time, test_message, commit_message)
# commit_line <- paste0("COMMIT_MESSAGE='", commit_text, "'", ' >> "$GITHUB_ENV"')
# system(paste('echo ', commit_line))

################################################################
# Social media post
# Only post if it's a major data update (additions or removals)
# If it's just one addition or removal, list the URL added/removed
# Otherwise just how many
################################################################

if (data_change == "Major") {
	# system('echo "POST_BSKY=true" >> "$GITHUB_ENV"')
	post_bsky <- T
	
	if (test_changes == T) {
		post_start <- paste(test_message, "The Census Bureau APIs")
	} else {
		post_start <- "The Census Bureau APIs"
	}
	
	if (length(urls_added) == 1) {
		added_text <- "added 1 dataset"
	} else if (length(urls_added) > 1){
		added_text <- paste("added", length(urls_added), "datasets")
	}
	
	if (length(urls_removed) == 1) {
		removed_text <- "removed 1 dataset"
	} else if (length(urls_removed) > 1){
		removed_text <- paste("removed", length(urls_removed), "datasets")
	}
	
	# Just one addition
	if (length(urls_added) == 1 & length(urls_removed) == 0) {
		post_content <- paste(post_start, "added 1 dataset:", gsub("http://api.census.gov/data/", "", urls_added))
		
		# More than one addition
	} else if (length(urls_added) > 1 & length(urls_removed) == 0) {
		post_content <- paste(post_start, added_text)
		
		# Just one removal
	}	else if (length(urls_added) == 0 & length(urls_removed) == 1) {
		post_content <- paste(post_start, "removed 1 dataset:", gsub("http://api.census.gov/data/", "", urls_removed))
		
		# More than one removal
	} else if (length(urls_added) == 0 & length(urls_removed) > 1) {
		post_content <- paste(post_start, removed_text)
		
		# Both addition(s) and removal(s)
	} else if (length(urls_added) > 0 & length(urls_removed) > 0){
		post_content <- paste(post_start, added_text, "and", removed_text)
		
		# Some weird behavior that shouldn't happen
	} else {
		system('echo "POST_BSKY=false" >> "$GITHUB_ENV"')
		post_content <- " "
	} 
	
	# post_part <- paste0("POST_TEXT='", post_content, "'", ' >> "$GITHUB_ENV"')
	# system(paste('echo ', post_part))
	# print(post_part)
} else {
	post_bsky <- F
	post_content <- " "
	# system('echo "POST_BSKY=false" >> "$GITHUB_ENV"')
	# system('echo "POST_TEXT= " >> "$GITHUB_ENV"')
}

################################################################
# Send vars to Github actions env
################################################################

send_env("COMMIT_CHANGES", commit_changes, send_output = TRUE)
send_env("COMMIT_MESSAGE", commit_text)
send_env("DATA_TEST", data_test)
send_env("UPDATED_DATA", updated_data)
send_env("POST_BSKY", post_bsky, send_output = TRUE)
send_env("POST_TEXT", post_content, send_output = TRUE)
