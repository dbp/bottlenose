class GradingConflictsController < ApplicationController
  
  layout 'course'

  before_action :find_course
  before_action :find_grading_conflict, only: [:update, :destroy, :resubmit_conflict_request]
  before_action :require_registered_user
  before_action :require_admin_or_prof, only: [:update]

  def index
    if current_user.course_professor?(@course) || current_user.site_admin
      @grading_conflicts = GradingConflict.where(course: @course)
    elsif current_user.course_assistant?(@course) || current_user.course_grader?(@course)
      @grading_conflicts = GradingConflict.where(course: @course, staff: current_user)
    else
      @grading_conflicts = GradingConflict.where(course: @course, student: current_user)
    end
  end

  def show
    find_grading_conflict
  end

  def new
    @tas_and_graders = Registration.where(course: @course)
      .where(role: Registration.roles[:grader])
      .or(Registration.where(role: Registration.roles[:assistant]))
      .map{|reg| reg.user}
    @students = Registration.where(course: @course, role: Registration.roles[:student])
      .map{|reg| reg.user}

    if current_user.course_grader?(@course) || current_user.course_assistant?(@course)
      @students = @students.select{ |s| !GradingConflict.exists?(course: @course, 
          student: s, staff: current_user) }
    elsif current_user.course_student?(@course)
      @tas_and_graders = @tas_and_graders.select {|s| !GradingConflict.exists?(course: @course,
          student: current_user, staff: s) }
    end

    # If a student or grader/TA has submitted ALL possible combinations
    # of themself with their counterparts, one of these lists will be 
    # empty (per the above if/elsif), and thus they will not be able
    # to submit another conflict.
    unless (@tas_and_graders.any? && @students.any?)
      redirect_to course_grading_conflicts_path(@course), 
        alert: "You cannot submit any more grading conflicts."
      return
    end
    
  end

  def edit
    find_grading_conflict
  end

  def update
    @grading_conflict.status = update_params[:status]
    update_audit = GradingConflictAudit.create(user: current_user, grading_conflict: @grading_conflict, 
      status: @grading_conflict.status, reason: update_params[:reason])
    @grading_conflict.grading_conflict_audits << update_audit

    if @grading_conflict.save! && update_audit.save!
      redirect_to course_grading_conflict_path(@course, @grading_conflict), 
        notice: "Successfully updated this conflict."
    else
      redirect_back edit_course_grading_conflict_path(@course, @grading_conflict),
        alert: "Error updating this grading conflict. Please contact an admin."
    end
  end

  # TODO: Add guard clause for exisitng conflict.
  def create
    if current_user.professor_ever? || current_user.site_admin?
      @grading_conflict = GradingConflict.create(student_id: gc_params[:student_id], staff_id: gc_params[:staff_id],
        course: @course)
    elsif staff_can_create_conflict?(gc_params[:student_id])
      @grading_conflict = GradingConflict.create(student_id: gc_params[:student_id], staff: current_user, course: @course)
      @grading_conflict.status = :pending
    elsif student_can_create_conflict?(gc_params[:staff_id])
      @grading_conflict = GradingConflict.create(student: current_user, staff_id: gc_params[:staff_id], course: @course)
      @grading_conflict.status = :pending
    else
      redirect_back new_course_grading_conflict_path(@course), 
        alert: "This conflict already exists."
      return
    end

    # TODO: Add audit information to creation of Grading Conflict
    creation_audit = GradingConflictAudit.create(grading_conflict: @grading_conflict,
      user: current_user, status: @grading_conflict.status, reason: gc_params[:reason])
    @grading_conflict.grading_conflict_audits << creation_audit

    if @grading_conflict.save! && creation_audit.save!
      redirect_to course_grading_conflicts_path(@course), 
            notice: "Successfully created a grading conflict."
    else
      redirect_back new_course_grading_conflict_path(@course),
            alert: "Error saving the grading conflict. Please contact a site admin."
    end
  end

  def destroy
    # TODO: Should prof/admin be able to delete this regardless of state?
    unless @grading_conflict.can_be_rejected?
      redirect_to course_grading_conflict_path(@course, @grading_conflict),
        alert: "This grading conflict cannot be deleted."
    end
    if @grading_conflict.destroy
      redirect_to course_grading_conflicts_path(@course), 
        notice: "Grading conflict was successfully deleted."
    else
      redirect_to course_grading_conflict(@course, @grading_conflict), 
        alert: "Grading conflict could not be deleted. Please contact a site admin."
    end
  end

  def resubmit_conflict_request
    @grading_conflict.status = :pending
    update_audit = GradingConflictAudit.create(user: current_user, grading_conflict: @grading_conflict,
      status: :pending, reason: update_params[:reason])
    @grading_conflict.grading_conflict_audits << update_audit

    if update_audit.save && @grading_conflict.save
      redirect_to course_grading_conflict_path(@course, @grading_conflict),
        notice: "Successfully resubmitted this grading conflict request."
    else
      redirect_back course_grading_conflict_path(@course, @grading_conflict), 
        alert: "An error has occurred resubmitting this grading conflict request. Please contact a site admin."
    end

  end

  private

  def gc_params
    ans = params.require(:grading_conflict).permit(:student_id, :staff_id, :reason)
    ans[:student_id] = params[:grading_conflict][:student_id]
    ans[:student_id] = params[:grading_conflict][:student_id]
    ans[:reason] = has_reason_param? ? params[:grading_conflict][:reason] : nil
    ans
  end

  def update_params
    ans = params.require(:grading_conflict).permit(:status, :reason)
    ans[:reason] = params[:grading_conflict][:reason]
    ans[:status] = params[:grading_conflict][:status]
    ans
  end

  def find_grading_conflict
    @grading_conflict = GradingConflict.find_by(id: params[:id])
    if @grading_conflict.nil? || @course.id != @grading_conflict.course_id
      redirect_to course_grading_conflicts_path(@course),
        alert: "No such grading conflict for this course."
      return
    end
  end

  def has_reason_param?
    return params[:grading_conflict].key?(:reason) && 
      !(params[:grading_conflict][:reason].nil? || 
        params[:grading_conflict][:reason] != "")
  end

  def student_can_create_conflict?(staff_id)
    return current_user.course_student?(@course) &&
      !GradingConflict.exists?(course: @course, student: current_user, staff_id: staff_id)
  end

  def staff_can_create_conflict?(student_id)
    return (current_user.course_grader?(@course) || 
      current_user.course_assistant?(@course)) &&
      !GradingConflict.exists?(course: @course, student_id: student_id, staff: current_user)
  end

end
